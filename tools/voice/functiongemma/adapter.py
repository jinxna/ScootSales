from __future__ import annotations

import importlib.util
import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping, Optional


_SCHEMA_VERSION = 1
_ACTION_ID = re.compile(r"^[a-z][a-z0-9_]{0,80}$")
_PARAMETER_NAME = re.compile(r"^[A-Za-z][A-Za-z0-9_]{0,80}$")
_INTEGER = re.compile(r"^-?(?:0|[1-9][0-9]*)$")
_WINDOWS_ABSOLUTE_PATH = re.compile(r"^[A-Za-z]:[\\/]")
_KNOWN_FUNCTION_TOKENS = (
    "<start_function_call>",
    "<end_function_call>",
    "<start_function_response>",
    "<start_of_turn>model",
    "<end_of_turn>",
)
_TOKENIZER_FILES = ("tokenizer.json", "tokenizer.model", "spiece.model", "vocab.json")
_WEIGHT_FILES = (
    "model.safetensors",
    "pytorch_model.bin",
    "model.safetensors.index.json",
    "pytorch_model.bin.index.json",
)


class ModelLoadError(RuntimeError):
    pass


class ModelArtifactError(ModelLoadError):
    pass


class DeviceSelectionError(ModelLoadError):
    pass


class OptionalDependencyError(ModelLoadError):
    pass


class _DuplicateFieldError(ValueError):
    pass


@dataclass(frozen=True)
class ActionProposal:
    schema_version: int
    action_id: str
    parameters: Mapping[str, Any]
    source: str = "functiongemma"


@dataclass(frozen=True)
class Rejection:
    reason: str
    detail: str = ""


@dataclass(frozen=True)
class ParseResult:
    proposal: Optional[ActionProposal] = None
    rejection: Optional[Rejection] = None

    @property
    def accepted(self) -> bool:
        return self.proposal is not None and self.rejection is None


class FunctionGemmaAdapter:
    def __init__(self, schema: Mapping[str, Any]) -> None:
        self._schema = _validate_schema(schema)
        self._actions = {
            action["actionId"]: action for action in self._schema["actions"]
        }
        self._runtime_model: Any = None
        self._runtime_processor: Any = None
        self._runtime_torch: Any = None
        self._runtime_model_id: Optional[str] = None
        self._runtime_device: Optional[str] = None

    @classmethod
    def from_schema_file(cls, path: Path) -> "FunctionGemmaAdapter":
        with path.open("r", encoding="utf-8") as stream:
            return cls(json.load(stream))

    @property
    def schema_version(self) -> int:
        return _SCHEMA_VERSION

    def prompt_for(self, transcript: str) -> str:
        command = transcript.strip()
        return (
            "Return exactly one function call for the supplied command. "
            "Return no explanation and no free text. Use only actionId values "
            "and parameter names from this schema. If the request is unsafe, "
            "unsupported, ambiguous, compound, or missing required context, "
            "abstain by returning no call. The host application performs all "
            "entity, role, screen, current-state, and confirmation checks.\n"
            f"Schema: {json.dumps(self._schema, separators=(',', ':'))}\n"
            f"Command: {command}"
        )

    def _function_tools(self) -> list[dict[str, Any]]:
        tools: list[dict[str, Any]] = []
        for action in self._schema["actions"]:
            if (
                not action["enabled"]
                or not action["allowOffline"]
                or action["risk"] in {"red", "blocked"}
            ):
                continue
            properties: dict[str, Any] = {}
            required: list[str] = []
            for name, specification in action["parameters"].items():
                properties[name] = dict(specification)
                required.append(name)
            parameters: dict[str, Any] = {
                "type": "object",
                "properties": properties,
            }
            if required:
                parameters["required"] = required
            tools.append(
                {
                    "type": "function",
                    "function": {
                        "name": action["actionId"],
                        "description": action["description"],
                        "parameters": parameters,
                    },
                }
            )
        return tools

    def parse_output(self, text: str) -> ParseResult:
        raw = text.strip()
        if not raw:
            return _reject("empty_output", "The model returned no call.")

        json_result = self._parse_json(raw)
        if json_result is not None:
            return json_result
        return self._parse_function_call(raw)

    def load(
        self,
        model_id: str | Path,
        *,
        device: Optional[str] = None,
    ) -> dict[str, Any]:
        self._ensure_runtime(model_id, device)
        return self.runtime_info()

    def generate(
        self,
        transcript: str,
        *,
        model_id: str | Path,
        max_new_tokens: int = 96,
        device: Optional[str] = None,
    ) -> ParseResult:
        if max_new_tokens < 1 or max_new_tokens > 512:
            raise ValueError("max_new_tokens must be between 1 and 512")

        processor, model, torch = self._ensure_runtime(model_id, device)

        messages = [
            {
                "role": "developer",
                "content": "You are a model that can do function calling with the following functions",
            },
            {"role": "user", "content": transcript.strip()},
        ]
        inputs = processor.apply_chat_template(
            messages,
            tools=self._function_tools(),
            add_generation_prompt=True,
            return_dict=True,
            return_tensors="pt",
        )
        inputs = _move_inputs_to_model(inputs, model, self._runtime_device)
        with torch.inference_mode():
            generation_kwargs: dict[str, Any] = {
                "max_new_tokens": max_new_tokens,
            }
            pad_token_id = _pad_token_id(processor)
            if pad_token_id is not None:
                generation_kwargs["pad_token_id"] = pad_token_id
            output = model.generate(**inputs, **generation_kwargs)

        input_ids = inputs.get("input_ids")
        generated = output[0]
        if input_ids is not None:
            generated = generated[input_ids.shape[-1] :]
        generated_text = processor.decode(generated, skip_special_tokens=False)
        return self.parse_output(generated_text)

    def generate_batch(
        self,
        transcripts: list[str],
        *,
        model_id: str | Path,
        max_new_tokens: int = 96,
        device: Optional[str] = None,
    ) -> list[ParseResult]:
        if not transcripts:
            return []
        if max_new_tokens < 1 or max_new_tokens > 512:
            raise ValueError("max_new_tokens must be between 1 and 512")

        processor, model, torch = self._ensure_runtime(model_id, device)
        developer_message = {
            "role": "developer",
            "content": "You are a model that can do function calling with the following functions",
        }
        conversations = [
            [developer_message, {"role": "user", "content": transcript.strip()}]
            for transcript in transcripts
        ]
        inputs = processor.apply_chat_template(
            conversations,
            tools=self._function_tools(),
            add_generation_prompt=True,
            padding=True,
            return_dict=True,
            return_tensors="pt",
        )
        inputs = _move_inputs_to_model(inputs, model, self._runtime_device)
        with torch.inference_mode():
            generation_kwargs: dict[str, Any] = {
                "max_new_tokens": max_new_tokens,
            }
            pad_token_id = _pad_token_id(processor)
            if pad_token_id is not None:
                generation_kwargs["pad_token_id"] = pad_token_id
            output = model.generate(**inputs, **generation_kwargs)

        input_ids = inputs.get("input_ids")
        prompt_length = input_ids.shape[-1] if input_ids is not None else 0
        return [
            self.parse_output(
                processor.decode(row[prompt_length:], skip_special_tokens=False)
            )
            for row in output
        ]

    def _ensure_runtime(
        self,
        model_id: str | Path,
        device: Optional[str],
    ) -> tuple[Any, Any, Any]:
        model_reference = _normalise_model_id(model_id)
        if self._runtime_model is None:
            _validate_model_reference(model_reference)
            try:
                import torch  # type: ignore
            except ImportError as error:
                raise OptionalDependencyError(
                    "Optional FunctionGemma evaluation needs transformers and torch. "
                    "Install them in a development environment only; production "
                    "Flutter requirements are unchanged."
                ) from error

            resolved_device = _normalise_device(torch, device)
            try:
                from transformers import AutoModelForCausalLM, AutoProcessor  # type: ignore
            except ImportError as error:
                raise OptionalDependencyError(
                    "Optional FunctionGemma evaluation needs transformers and torch. "
                    "Install them in a development environment only; production "
                    "Flutter requirements are unchanged."
                ) from error

            try:
                processor = AutoProcessor.from_pretrained(
                    model_reference,
                    local_files_only=True,
                )
            except Exception as error:
                raise ModelArtifactError(
                    _format_loader_error("processor", model_reference, error)
                ) from error
            model_kwargs: dict[str, Any] = {
                "local_files_only": True,
                "dtype": "auto",
            }
            if resolved_device is None and _has_accelerate():
                model_kwargs["device_map"] = "auto"
            try:
                model = AutoModelForCausalLM.from_pretrained(
                    model_reference,
                    **model_kwargs,
                )
            except Exception as error:
                raise ModelArtifactError(
                    _format_loader_error("checkpoint", model_reference, error)
                ) from error
            try:
                if resolved_device is not None:
                    model = model.to(resolved_device)
                model.eval()
            except Exception as error:
                raise ModelLoadError(
                    _format_device_load_error(model_reference, resolved_device, error)
                ) from error
            self._runtime_torch = torch
            self._runtime_processor = processor
            self._runtime_model = model
            self._runtime_model_id = model_reference
            self._runtime_device = resolved_device
        elif self._runtime_model_id != model_reference or self._runtime_device != _normalise_device(self._runtime_torch, device):
            raise ValueError(
                "This adapter instance is already loaded for a different model or device."
            )

        return self._runtime_processor, self._runtime_model, self._runtime_torch

    def runtime_info(self) -> dict[str, Any]:
        if self._runtime_model is None:
            return {}

        parameter_count: Optional[int] = None
        try:
            parameter_count = sum(
                int(parameter.numel())
                for parameter in self._runtime_model.parameters()
            )
        except (AttributeError, TypeError, RuntimeError):
            pass

        footprint_bytes: Optional[int] = None
        transformers_artifact_bytes: Optional[int] = None
        litert_artifact_bytes: Optional[int] = None
        model_path = Path(self._runtime_model_id or "")
        if model_path.is_file():
            footprint_bytes = model_path.stat().st_size
            if model_path.suffix.lower() == ".litertlm":
                litert_artifact_bytes = footprint_bytes
            else:
                transformers_artifact_bytes = footprint_bytes
        elif model_path.is_dir():
            files = [path for path in model_path.rglob("*") if path.is_file()]
            footprint_bytes = sum(path.stat().st_size for path in files)
            litert_artifact_bytes = sum(
                path.stat().st_size
                for path in files
                if path.suffix.lower() == ".litertlm"
            )
            transformers_artifact_bytes = footprint_bytes - litert_artifact_bytes

        resident_bytes: Optional[int] = None
        try:
            import psutil  # type: ignore

            resident_bytes = int(psutil.Process().memory_info().rss)
        except (ImportError, OSError, AttributeError, RuntimeError):
            pass

        return {
            "modelId": self._runtime_model_id,
            "device": str(getattr(self._runtime_model, "device", self._runtime_device)),
            "parameterCount": parameter_count,
            "footprintBytes": footprint_bytes,
            "transformersArtifactBytes": transformers_artifact_bytes,
            "liteRtArtifactBytes": litert_artifact_bytes,
            "residentBytes": resident_bytes,
        }

    def _parse_json(self, raw: str) -> Optional[ParseResult]:
        candidate = raw
        for token in _KNOWN_FUNCTION_TOKENS:
            candidate = candidate.replace(token, "")
        candidate = candidate.strip()
        if not candidate.startswith("{"):
            return None
        try:
            decoded = json.loads(
                candidate,
                object_pairs_hook=_reject_duplicate_fields,
                parse_constant=_reject_json_constant,
            )
        except _DuplicateFieldError as error:
            return _reject("duplicate_fields", str(error))
        except (TypeError, ValueError, json.JSONDecodeError) as error:
            return _reject("malformed_json", str(error))
        if not isinstance(decoded, dict):
            return _reject("malformed_json", "The call envelope must be an object.")

        if "calls" in decoded:
            if set(decoded) != {"schemaVersion", "calls"}:
                return _reject("unknown_fields", "The call envelope has unknown fields.")
            calls = decoded["calls"]
            if not isinstance(calls, list) or len(calls) != 1:
                return _reject("multiple_calls", "Exactly one function call is required.")
            call = calls[0]
            if not isinstance(call, dict):
                return _reject("malformed_call", "The function call must be an object.")
            if set(call) != {"actionId", "parameters"}:
                return _reject("unknown_fields", "The function call has unknown fields.")
            return self._proposal_from_values(
                decoded.get("schemaVersion"), call.get("actionId"), call.get("parameters")
            )

        if set(decoded) != {"schemaVersion", "actionId", "parameters"}:
            return _reject("unknown_fields", "The call envelope has unknown fields.")
        return self._proposal_from_values(
            decoded.get("schemaVersion"),
            decoded.get("actionId"),
            decoded.get("parameters"),
        )

    def _parse_function_call(self, raw: str) -> ParseResult:
        matches = list(re.finditer(r"call:([a-z][a-z0-9_]*)\s*\{", raw))
        if len(matches) == 0:
            return _reject("malformed_call", "No supported function-call envelope was found.")
        if len(matches) != 1:
            return _reject("multiple_calls", "Exactly one function call is required.")

        match = matches[0]
        closing = _matching_brace(raw, match.end() - 1)
        if closing is None:
            if raw[match.end() :].count("<escape>") % 2:
                return _reject(
                    "malformed_parameters",
                    "Escaped function values must have a closing delimiter.",
                )
            return _reject("malformed_call", "The function-call arguments are not closed.")

        prefix = raw[: match.start()]
        suffix = raw[closing + 1 :]
        if _remove_known_tokens(prefix).strip() or _remove_known_tokens(suffix).strip():
            return _reject("free_text", "Only the function-call envelope is accepted.")

        parameters = _parse_function_arguments(raw[match.end() : closing])
        if isinstance(parameters, Rejection):
            return ParseResult(rejection=parameters)
        return self._proposal_from_values(
            _SCHEMA_VERSION,
            match.group(1),
            parameters,
        )

    def _proposal_from_values(
        self,
        schema_version: Any,
        action_id: Any,
        parameters: Any,
    ) -> ParseResult:
        if type(schema_version) is not int or schema_version != _SCHEMA_VERSION:
            return _reject("unsupported_schema", "Only schemaVersion 1 is accepted.")
        if not isinstance(action_id, str) or not _ACTION_ID.fullmatch(action_id):
            return _reject("unknown_action", "The actionId is not recognised.")
        action = self._actions.get(action_id)
        if action is None:
            return _reject("unknown_action", f"Unknown actionId: {action_id}")
        if (
            action["risk"] in {"red", "blocked"}
            or not action["enabled"]
            or not action["allowOffline"]
        ):
            return _reject(
                "unsafe_action",
                f"The action is disabled or unavailable offline: {action_id}",
            )
        if not isinstance(parameters, dict):
            return _reject("malformed_parameters", "parameters must be an object.")

        expected = action["parameters"]
        if set(parameters) != set(expected):
            return _reject("unknown_or_missing_parameters", "Parameter names do not match the registry.")
        for name, specification in expected.items():
            failure = _validate_parameter(name, parameters[name], specification)
            if failure is not None:
                return _reject("invalid_parameters", failure)

        return ParseResult(
            proposal=ActionProposal(
                schema_version=_SCHEMA_VERSION,
                action_id=action_id,
                parameters=dict(parameters),
            )
        )


def _normalise_model_id(model_id: str | Path) -> str:
    if model_id is None or not isinstance(model_id, (str, Path)):
        raise ValueError(
            "model_id must be a local Transformers directory or a cached model ID"
        )
    reference = str(model_id).strip()
    if not reference:
        raise ValueError("model_id is required when model inference is requested")
    return reference


def _local_model_path(reference: str) -> Optional[Path]:
    candidate = Path(reference).expanduser()
    try:
        exists = candidate.exists()
        absolute = candidate.is_absolute()
    except OSError:
        exists = False
        absolute = False
    if (
        exists
        or absolute
        or _WINDOWS_ABSOLUTE_PATH.match(reference)
        or reference.startswith((".", "/", "\\"))
        or "\\" in reference
    ):
        return candidate
    return None


def _validate_model_reference(reference: str) -> None:
    path = _local_model_path(reference)
    if path is None:
        return

    try:
        if not path.exists():
            raise ModelArtifactError(
                f"Local FunctionGemma model path does not exist: '{path}'. "
                "No network download was attempted; provide the downloaded "
                "Transformers directory or a cached model ID."
            )
        if path.is_file():
            if path.suffix.lower() == ".litertlm":
                raise ModelArtifactError(
                    f"'{path}' is a LiteRT-LM (.litertlm) artifact, not a "
                    "Transformers checkpoint directory. This adapter accepts "
                    "config.json, tokenizer files, and PyTorch/Safetensors "
                    "weights; no network download was attempted."
                )
            raise ModelArtifactError(
                f"Local FunctionGemma model reference '{path}' is a file. "
                "Pass the Transformers checkpoint directory, not an individual "
                "model file; no network download was attempted."
            )
        if not path.is_dir():
            raise ModelArtifactError(
                f"Local FunctionGemma model reference '{path}' is not a directory. "
                "No network download was attempted."
            )
    except OSError as error:
        raise ModelArtifactError(
            f"Local FunctionGemma model path '{path}' could not be inspected: "
            f"{type(error).__name__}: {error}. No network download was attempted."
        ) from error

    _validate_transformers_directory(path)


def _validate_transformers_directory(path: Path) -> None:
    missing: list[str] = []
    config_path = path / "config.json"
    if not config_path.is_file():
        missing.append("config.json")
    else:
        try:
            config = json.loads(config_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, TypeError, ValueError) as error:
            raise ModelArtifactError(
                f"Local FunctionGemma model has an invalid config.json at "
                f"'{config_path}': {type(error).__name__}: {error}."
            ) from error
        if not isinstance(config, dict):
            raise ModelArtifactError(
                f"Local FunctionGemma model config '{config_path}' must contain "
                "a JSON object."
            )

    if not _has_transformers_weights(path):
        missing.append(
            "a Transformers weight file (model.safetensors, pytorch_model.bin, "
            "or a sharded weight index)"
        )
    if not any((path / name).is_file() for name in _TOKENIZER_FILES):
        missing.append(
            "a tokenizer vocabulary (tokenizer.json, tokenizer.model, "
            "spiece.model, or vocab.json)"
        )
    if missing:
        hint = ""
        try:
            if any(item.is_file() for item in path.glob("*.litertlm")):
                hint = (
                    " A .litertlm file is present, but LiteRT-LM is not accepted "
                    "by this Transformers adapter."
                )
        except OSError:
            pass
        raise ModelArtifactError(
            f"Local FunctionGemma model directory '{path}' is incomplete. "
            f"Missing {', '.join(missing)}.{hint} No network download was attempted."
        )

    for index_name in ("model.safetensors.index.json", "pytorch_model.bin.index.json"):
        index_path = path / index_name
        if index_path.is_file():
            _validate_weight_index(path, index_path)


def _has_transformers_weights(path: Path) -> bool:
    if any((path / name).is_file() for name in _WEIGHT_FILES):
        return True
    try:
        for item in path.iterdir():
            if not item.is_file():
                continue
            if item.name.startswith("model-") and item.suffix == ".safetensors":
                return True
            if item.name.startswith("pytorch_model-") and item.suffix == ".bin":
                return True
    except OSError:
        return False
    return False


def _validate_weight_index(path: Path, index_path: Path) -> None:
    try:
        payload = json.loads(index_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, TypeError, ValueError) as error:
        raise ModelArtifactError(
            f"Local FunctionGemma weight index '{index_path}' is invalid: "
            f"{type(error).__name__}: {error}."
        ) from error
    if not isinstance(payload, dict) or not isinstance(payload.get("weight_map"), dict):
        raise ModelArtifactError(
            f"Local FunctionGemma weight index '{index_path}' has no valid weight_map."
        )

    shards: set[str] = set()
    for shard in payload["weight_map"].values():
        if not isinstance(shard, str) or not shard.strip():
            raise ModelArtifactError(
                f"Local FunctionGemma weight index '{index_path}' contains an "
                "invalid shard name."
            )
        shards.add(shard)

    missing = []
    for shard in shards:
        shard_path = Path(shard)
        if shard_path.is_absolute() or ".." in shard_path.parts:
            missing.append(shard)
        elif not (path / shard_path).is_file():
            missing.append(shard)
    if missing:
        shown = ", ".join(missing[:5])
        if len(missing) > 5:
            shown += f", and {len(missing) - 5} more"
        raise ModelArtifactError(
            f"Local FunctionGemma weight index '{index_path}' references missing "
            f"or unsafe shard file(s): {shown}. No network download was attempted."
        )


def _normalise_device(torch: Any, device: Optional[str]) -> Optional[str]:
    if device is None:
        return None
    if not isinstance(device, str) or not device.strip():
        raise DeviceSelectionError(
            "The requested inference device must be a non-empty string such as "
            "'cpu' or 'cuda'."
        )

    normalised = device.strip().lower()
    if normalised == "cpu":
        return "cpu"

    if normalised == "mps":
        backends = getattr(torch, "backends", None)
        mps = getattr(backends, "mps", None)
        is_available = getattr(mps, "is_available", None)
        if not callable(is_available) or not bool(is_available()):
            raise DeviceSelectionError(
                "The requested 'mps' device is not available in this local "
                "PyTorch environment. Use --device cpu or install a supported "
                "accelerator runtime."
            )
        return "mps"

    if normalised == "cuda" or normalised.startswith("cuda:"):
        cuda = getattr(torch, "cuda", None)
        is_available = getattr(cuda, "is_available", None)
        if not callable(is_available) or not bool(is_available()):
            raise DeviceSelectionError(
                "CUDA was requested, but no CUDA-capable PyTorch runtime is "
                "available. Use --device cpu for this machine."
            )
        if normalised != "cuda":
            index_text = normalised.split(":", 1)[1]
            if not index_text.isdigit():
                raise DeviceSelectionError(
                    f"Invalid CUDA device '{device}'. Use 'cuda' or 'cuda:N'."
                )
            device_index = int(index_text)
            device_count = getattr(cuda, "device_count", None)
            if callable(device_count) and device_index >= int(device_count()):
                raise DeviceSelectionError(
                    f"CUDA device index {device_index} is not available in this "
                    "local PyTorch environment."
                )
        return normalised

    raise DeviceSelectionError(
        f"Unsupported inference device '{device}'. Use 'cpu', 'cuda', "
        "'cuda:N', or 'mps' when the local runtime supports it."
    )


def _has_accelerate() -> bool:
    try:
        return importlib.util.find_spec("accelerate") is not None
    except (ImportError, ValueError, AttributeError):
        return False


def _move_inputs_to_model(
    inputs: Any,
    model: Any,
    device: Optional[str],
) -> Any:
    target_device = device or getattr(model, "device", None)
    if target_device is None:
        return inputs

    move = getattr(inputs, "to", None)
    if callable(move):
        return move(target_device)

    if isinstance(inputs, Mapping):
        moved: dict[Any, Any] = {}
        for key, value in inputs.items():
            value_move = getattr(value, "to", None)
            moved[key] = value_move(target_device) if callable(value_move) else value
        return moved
    return inputs


def _pad_token_id(processor: Any) -> Optional[int]:
    for candidate in (processor, getattr(processor, "tokenizer", None)):
        if candidate is None:
            continue
        for attribute in ("pad_token_id", "eos_token_id"):
            value = getattr(candidate, attribute, None)
            if type(value) is int:
                return value
    return None


def _format_loader_error(kind: str, reference: str, error: Exception) -> str:
    return (
        f"Unable to load the local FunctionGemma {kind} from '{reference}'. "
        "No network download was attempted. Check that the Transformers "
        f"artifacts are complete and readable ({type(error).__name__}: {error})."
    )


def _format_device_load_error(
    reference: str,
    device: Optional[str],
    error: Exception,
) -> str:
    selected = device or "automatic placement"
    return (
        f"The local FunctionGemma model '{reference}' could not be placed on "
        f"{selected} ({type(error).__name__}: {error}). Try --device cpu or "
        "check the local accelerator installation."
    )


def _validate_schema(schema: Mapping[str, Any]) -> dict[str, Any]:
    if not isinstance(schema, Mapping):
        raise ValueError("FunctionGemma schema must be an object")
    if set(schema) != {"schemaVersion", "actions"}:
        raise ValueError("FunctionGemma schema has unknown top-level fields")
    if schema["schemaVersion"] != _SCHEMA_VERSION or not isinstance(schema["actions"], list):
        raise ValueError("FunctionGemma schema must use schemaVersion 1 and an action list")

    seen: set[str] = set()
    actions: list[dict[str, Any]] = []
    for action in schema["actions"]:
        if not isinstance(action, dict):
            raise ValueError("Each action definition must be an object")
        required = {
            "actionId",
            "description",
            "risk",
            "enabled",
            "requiresConfirmation",
            "allowOffline",
            "requiresAuthenticatedUser",
            "permittedRoles",
            "permittedSurfaces",
            "parameters",
        }
        if set(action) != required:
            raise ValueError("Action definition fields do not match the frozen schema")
        action_id = action["actionId"]
        if not isinstance(action_id, str) or not _ACTION_ID.fullmatch(action_id):
            raise ValueError("Action IDs must use the lower snake_case format")
        if not isinstance(action["description"], str) or not action["description"].strip():
            raise ValueError(f"Action descriptions must be non-empty: {action_id}")
        if action_id in seen:
            raise ValueError(f"Duplicate action ID: {action_id}")
        seen.add(action_id)
        if action["risk"] not in {"green", "yellow", "red", "blocked"}:
            raise ValueError(f"Unknown action risk: {action_id}")
        if (
            not isinstance(action["enabled"], bool)
            or not isinstance(action["requiresConfirmation"], bool)
            or not isinstance(action["allowOffline"], bool)
            or not isinstance(action["requiresAuthenticatedUser"], bool)
        ):
            raise ValueError(f"Action flags are invalid: {action_id}")
        if not isinstance(action["parameters"], dict):
            raise ValueError(f"Action parameters are invalid: {action_id}")
        for parameter_name, specification in action["parameters"].items():
            if not isinstance(parameter_name, str) or not _PARAMETER_NAME.fullmatch(parameter_name):
                raise ValueError(f"Invalid parameter name: {parameter_name}")
            if not isinstance(specification, dict) or "type" not in specification:
                raise ValueError(f"Invalid parameter specification: {parameter_name}")
        actions.append(dict(action))
    return {"schemaVersion": _SCHEMA_VERSION, "actions": actions}


def _validate_parameter(name: str, value: Any, specification: Mapping[str, Any]) -> Optional[str]:
    parameter_type = specification.get("type")
    if parameter_type == "string":
        if not isinstance(value, str):
            return f"{name} must be a string"
        if len(value.strip()) < int(specification.get("minLength", 0)):
            return f"{name} is empty"
        if len(value) > int(specification.get("maxLength", 200)):
            return f"{name} is too long"
        allowed = specification.get("enum")
        if allowed is not None and value not in allowed:
            return f"{name} is not an allowed value"
        return None
    if parameter_type == "integer":
        if type(value) is not int:
            return f"{name} must be an integer"
        if "minimum" in specification and value < specification["minimum"]:
            return f"{name} is below the minimum"
        if "maximum" in specification and value > specification["maximum"]:
            return f"{name} is above the maximum"
        return None
    return f"{name} has an unsupported type"


def _parse_function_arguments(body: str) -> dict[str, Any] | Rejection:
    if not body.strip():
        return {}
    result: dict[str, Any] = {}
    for part in _split_top_level(body, ","):
        if ":" not in part:
            return Rejection("malformed_parameters", "Every argument needs a name and value.")
        name, raw_value = part.split(":", 1)
        name = name.strip()
        if not _PARAMETER_NAME.fullmatch(name) or name in result:
            return Rejection("unknown_or_duplicate_parameters", "Parameter names are invalid or duplicated.")
        decoded = _decode_function_value(raw_value.strip())
        if isinstance(decoded, Rejection):
            return decoded
        result[name] = decoded
    return result


def _decode_function_value(raw: str) -> Any:
    if raw.startswith("<escape>"):
        raw = raw[len("<escape>") :]
        if not raw.endswith("<escape>"):
            return Rejection(
                "malformed_parameters",
                "Escaped function values must have a closing delimiter.",
            )
        return raw[: -len("<escape>")]
    if "<escape>" in raw or "</escape>" in raw:
        return Rejection(
            "malformed_parameters",
            "Escaped function values must use matching delimiters.",
        )
    if raw.startswith('"') and raw.endswith('"'):
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            return raw[1:-1]
    if raw == "true":
        return True
    if raw == "false":
        return False
    if raw == "null":
        return None
    if _INTEGER.fullmatch(raw):
        return int(raw)
    return raw


def _split_top_level(value: str, separator: str) -> list[str]:
    parts: list[str] = []
    start = 0
    quote = False
    escaped = False
    escape_block = False
    depth = 0
    index = 0
    while index < len(value):
        if value.startswith("<escape>", index):
            escape_block = not escape_block
            index += len("<escape>")
            continue
        character = value[index]
        if escape_block:
            index += 1
            continue
        if escaped:
            escaped = False
            index += 1
            continue
        if character == "\\" and quote:
            escaped = True
            index += 1
            continue
        if character == '"':
            quote = not quote
            index += 1
            continue
        if not quote and character in "{[":
            depth += 1
        elif not quote and character in "}]":
            depth -= 1
        elif not quote and depth == 0 and character == separator:
            parts.append(value[start:index])
            start = index + 1
        index += 1
    parts.append(value[start:])
    return parts


def _matching_brace(value: str, opening: int) -> Optional[int]:
    depth = 0
    quote = False
    escaped = False
    escape_block = False
    index = opening
    while index < len(value):
        if value.startswith("<escape>", index):
            escape_block = not escape_block
            index += len("<escape>")
            continue
        character = value[index]
        if escape_block:
            index += 1
            continue
        if escaped:
            escaped = False
            index += 1
            continue
        if character == "\\" and quote:
            escaped = True
            index += 1
            continue
        if character == '"':
            quote = not quote
        elif not quote and character == "{":
            depth += 1
        elif not quote and character == "}":
            depth -= 1
            if depth == 0:
                return index
        index += 1
    return None


def _remove_known_tokens(value: str) -> str:
    for token in _KNOWN_FUNCTION_TOKENS:
        value = value.replace(token, "")
    return value


def _reject(reason: str, detail: str) -> ParseResult:
    return ParseResult(rejection=Rejection(reason=reason, detail=detail))


def _reject_duplicate_fields(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise _DuplicateFieldError(f"Duplicate JSON field: {key}")
        result[key] = value
    return result


def _reject_json_constant(value: str) -> None:
    raise ValueError(f"JSON constant is not allowed: {value}")
