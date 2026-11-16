from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable
from urllib.parse import urlsplit

MANIFEST_HELP = """Write release identity and hashes beside a completed build."""


SAFE_DEFINE_VALIDATORS = {
    "USE_FIREBASE_EMULATOR": lambda value: value in {"true", "false"},
    "FIREBASE_EMULATOR_HOST": lambda value: value in {"127.0.0.1", "localhost", "::1"},
    "FIRESTORE_EMULATOR_PORT": lambda value: _is_port(value),
    "FIREBASE_AUTH_EMULATOR_PORT": lambda value: _is_port(value),
    "FIREBASE_TARGET": lambda value: value in {"supermarket", "hardware"},
    "EDITION": lambda value: value in {"basic", "advanced"},
    "COPILOT_URL": lambda value: _is_safe_service_origin(value),
    "FORECAST_API": lambda value: _is_safe_service_origin(value),
    "PLATFORM_API_URL": lambda value: _is_safe_service_origin(value),
    "PLATFORM_PUBLIC_KEYS": lambda value: _is_public_key_bundle(value),
    "COMPANY_LOOKUP_URL": lambda value: _is_company_lookup_url(value),
    "COMPANY_REGISTRY_KEYS": lambda value: _is_public_key_bundle(value),
}
FIREBASE_PROJECTS = {
    "supermarket": "cos40005",
    "hardware": "hardware-client-sales",
    "runtime": None,
}
SOURCE_FILES = (
    Path("admin_dashboard/firestore.rules"),
    Path("admin_dashboard/firestore.indexes.json"),
)
VERSION_PATTERN = re.compile(r"^\d+\.\d+\.\d+$")


def _is_port(value: str) -> bool:
    return value.isdecimal() and 1 <= int(value) <= 65535


def _is_valid_hostname(hostname: str) -> bool:
    try:
        ipaddress.ip_address(hostname)
        return True
    except ValueError:
        normalized = hostname.rstrip(".")
        if not normalized or len(normalized) > 253:
            return False
        labels = normalized.split(".")
        return all(
            1 <= len(label) <= 63
            and re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?", label)
            for label in labels
        )


def _is_safe_service_origin(value: str) -> bool:
    try:
        if any(character.isspace() for character in value):
            return False
        parsed = urlsplit(value)
        hostname = parsed.hostname
        if (
            parsed.scheme not in {"http", "https"}
            or hostname is None
            or not _is_valid_hostname(hostname)
            or parsed.username is not None
            or parsed.password is not None
            or parsed.query
            or parsed.fragment
            or parsed.path not in {"", "/"}
        ):
            return False
        if parsed.port is not None and not 1 <= parsed.port <= 65535:
            return False
        if parsed.scheme == "https":
            return True
        return hostname.lower() in {"127.0.0.1", "localhost", "::1"} and parsed.port is not None
    except ValueError:
        return False


def _is_public_key_bundle(value: str) -> bool:
    return bool(re.fullmatch(
        r"[a-z0-9][a-z0-9._-]{0,63}=[A-Za-z0-9_-]{43}"
        r"(?:,[a-z0-9][a-z0-9._-]{0,63}=[A-Za-z0-9_-]{43})*", value
    ))


def _is_company_lookup_url(value: str) -> bool:
    try:
        if any(character.isspace() for character in value) or "?" in value or "#" in value:
            return False
        parsed = urlsplit(value)
        hostname = parsed.hostname
        if (
            parsed.scheme not in {"http", "https"}
            or parsed.path != "/v1/companies"
            or hostname is None
            or not _is_valid_hostname(hostname)
            or parsed.username is not None
            or parsed.password is not None
            or parsed.netloc.endswith(":")
        ):
            return False
        if parsed.port is not None and not 1 <= parsed.port <= 65535:
            return False
        if parsed.scheme == "https":
            return True
        return hostname.lower() in {"127.0.0.1", "localhost", "::1"} and parsed.port is not None
    except ValueError:
        return False


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def git_commit(repo_root: Path) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo_root), "rev-parse", "HEAD"],
        check=True,
        capture_output=True,
        text=True,
    )
    commit = result.stdout.strip()
    if not re.fullmatch(r"[0-9a-fA-F]{40,64}", commit):
        raise RuntimeError("Git did not return a valid commit ID.")
    return commit


def git_worktree_dirty(repo_root: Path) -> bool:
    result = subprocess.run(
        ["git", "-C", str(repo_root), "status", "--porcelain", "--untracked-files=normal"],
        check=True,
        capture_output=True,
        text=True,
    )
    return bool(result.stdout.strip())


def configuration_hashes(
    repo_root: Path, app_dir: Path, platform: str, runtime_identity: bool = False,
) -> dict[str, str]:
    relative_app = app_dir.relative_to(repo_root)
    paths = [
        Path("e2e/build.cjs"),
        relative_app / "pubspec.yaml",
    ]
    if runtime_identity:
        paths.append(relative_app / "lib" / "app" / "workspace_runtime.dart")
        paths.append(Path("packages/scoot_directory_client/lib/src/signed_envelope.dart"))
        paths.append(Path("flutter_mobile_app/pubspec.yaml"))
    else:
        paths.append(relative_app / "lib" / "firebase_options.dart")
    if platform == "android":
        paths.append(relative_app / "android" / "app" / "build.gradle.kts")
    hashes = {}
    for relative in paths:
        source = repo_root / relative
        if not source.is_file():
            raise FileNotFoundError(f"Required build configuration is missing: {relative.as_posix()}")
        hashes[relative.as_posix()] = sha256_file(source)
    return dict(sorted(hashes.items()))


def _safe_defines(defines: Iterable[str]) -> dict[str, str]:
    safe = {}
    for item in defines:
        key, separator, value = item.partition("=")
        if not separator or not key:
            raise ValueError("Build defines must use KEY=VALUE format.")
        validator = SAFE_DEFINE_VALIDATORS.get(key)
        if validator is None:
            continue
        if key in safe:
            raise ValueError(f"Duplicate build define: {key}")
        if not validator(value):
            raise ValueError(f"Unsafe or invalid value for build define {key}.")
        safe[key] = value
    return safe


def _app_version(app_dir: Path) -> str:
    pubspec = app_dir / "pubspec.yaml"
    if not pubspec.is_file():
        raise FileNotFoundError(f"Mobile app version file not found: {pubspec}")
    match = re.search(r"(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)(?:\+[0-9]+)?\s*$", pubspec.read_text(encoding="utf-8"))
    if not match:
        raise ValueError("Could not read a semantic version from the selected app's pubspec.yaml.")
    return match.group(1)


def _write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp_name = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=path.parent, delete=False
        ) as stream:
            temp_name = stream.name
            json.dump(data, stream, indent=2, sort_keys=True)
            stream.write("\n")
        os.replace(temp_name, path)
    finally:
        if temp_name and os.path.exists(temp_name):
            os.unlink(temp_name)


def _is_sensitive_name(name: str) -> bool:
    lowered = name.lower()
    return (
        ".env" in lowered
        or lowered == "key.properties"
        or (lowered.startswith("serviceaccountkey") and lowered.endswith(".json"))
        or lowered.endswith(".jks")
        or lowered.endswith(".keystore")
    )


def _safe_output_paths(build_dir: Path) -> list[Path]:
    files_to_hash = []
    sensitive_found = False
    symlink_found = False
    for root, dirs, files in os.walk(build_dir, followlinks=False):
        root_path = Path(root)
        kept_dirs = []
        for name in dirs:
            path = root_path / name
            sensitive_found |= _is_sensitive_name(name)
            if path.is_symlink():
                symlink_found = True
            else:
                kept_dirs.append(name)
        dirs[:] = kept_dirs
        for name in files:
            path = root_path / name
            sensitive_found |= _is_sensitive_name(name)
            if path.is_symlink():
                symlink_found = True
                continue
            if path.is_file():
                files_to_hash.append(path)
    if sensitive_found:
        raise ValueError("Build output contains a sensitive filename; refusing to read it.")
    if symlink_found:
        raise ValueError("Build output contains a symlink; refusing an incomplete manifest.")
    return sorted(files_to_hash)


def _output_hashes(build_dir: Path) -> dict[str, str]:
    hashes = {}
    for path in _safe_output_paths(build_dir):
        relative = path.relative_to(build_dir).as_posix()
        if relative == "release-manifest.json":
            continue
        hashes[relative] = sha256_file(path)
    return dict(sorted(hashes.items()))


def create_release_metadata(
    repo_root: Path,
    build_dir: Path,
    platform: str,
    firebase_target: str,
    app: str,
    edition: str,
    defines: Iterable[str] = (),
    minimum_supported_app_version: str | None = None,
    commit: str | None = None,
    worktree_dirty: bool | None = None,
    now: datetime | None = None,
    app_dir: Path | str | None = None,
) -> dict:
    repo_root = Path(repo_root).resolve()
    if platform not in {"web", "android"}:
        raise ValueError("Platform must be web or android.")
    if firebase_target not in FIREBASE_PROJECTS:
        raise ValueError("Firebase target must be supermarket, hardware or runtime.")
    if app not in {"admin", "mobile"}:
        raise ValueError("App must be admin or mobile.")
    runtime_identity = firebase_target == "runtime"
    if runtime_identity and (app != "admin" or platform != "web" or edition != "runtime"):
        raise ValueError("A runtime identity requires the shared admin web app and runtime edition.")
    if edition not in ({"runtime"} if runtime_identity else {"basic", "advanced"}):
        raise ValueError("Edition does not match the static or runtime build identity.")

    selected_app = Path(app_dir) if app_dir is not None else Path(
        "admin_dashboard" if app == "admin" else "flutter_mobile_app"
    )
    if not selected_app.is_absolute():
        selected_app = repo_root / selected_app
    selected_app = selected_app.absolute()
    try:
        relative_app = selected_app.relative_to(repo_root)
        if not relative_app.parts or ".." in relative_app.parts:
            raise ValueError("Invalid app directory.")
    except ValueError as error:
        raise ValueError("App directory must be inside the repository.") from error
    app_cursor = repo_root
    for component in relative_app.parts:
        app_cursor /= component
        if app_cursor.is_symlink():
            raise ValueError("App directory path cannot contain symlinks.")
    selected_app = selected_app.resolve()

    requested_build_dir = Path(build_dir)
    if not requested_build_dir.is_absolute():
        requested_build_dir = repo_root / requested_build_dir
    requested_build_dir = requested_build_dir.absolute()
    try:
        relative_build_path = requested_build_dir.relative_to(repo_root)
    except ValueError as error:
        raise ValueError("Build directory must be inside the repository.") from error
    path_cursor = repo_root
    for component in relative_build_path.parts:
        path_cursor = path_cursor / component
        if path_cursor.is_symlink():
            raise ValueError("Build directory path cannot contain symlinks.")
    build_dir = requested_build_dir.resolve()
    app_build_root = (selected_app / "build").resolve()
    qa_build_root = (repo_root / "qa_artifacts" / "p3-release-ops" / "builds").resolve()

    def is_build_child(path: Path, parent: Path) -> bool:
        try:
            path.relative_to(parent)
            return path != parent
        except ValueError:
            return False

    if not (is_build_child(build_dir, app_build_root) or is_build_child(build_dir, qa_build_root)):
        raise ValueError("Build directory must be a child of the selected app build or dedicated QA build directory.")
    if not build_dir.is_dir():
        raise FileNotFoundError(f"release build directory does not exist: {build_dir}")
    _safe_output_paths(build_dir)

    minimum = minimum_supported_app_version or _app_version(
        repo_root / "flutter_mobile_app" if app == "admin" else selected_app
    )
    if not VERSION_PATTERN.fullmatch(minimum):
        raise ValueError("Minimum supported app version must use MAJOR.MINOR.PATCH.")
    commit_id = commit or git_commit(repo_root)
    if not re.fullmatch(r"[0-9a-fA-F]{40,64}", commit_id):
        raise ValueError("Commit ID must be a full Git hash.")
    is_dirty = git_worktree_dirty(repo_root) if worktree_dirty is None else worktree_dirty
    created = now or datetime.now(timezone.utc)
    if created.tzinfo is None:
        raise ValueError("Creation time must include a timezone.")
    created_utc = created.astimezone(timezone.utc).replace(microsecond=0)
    created_text = created_utc.isoformat().replace("+00:00", "Z")
    build_defines = _safe_defines(defines)
    define_target = build_defines.get("FIREBASE_TARGET")
    if runtime_identity and (define_target is not None or "EDITION" in build_defines):
        raise ValueError("A runtime dashboard cannot carry static FIREBASE_TARGET or EDITION defines.")
    if not runtime_identity and define_target != firebase_target:
        raise ValueError("FIREBASE_TARGET define must match the manifest Firebase target.")
    if not runtime_identity and build_defines.get("EDITION") != edition:
        raise ValueError("EDITION define must match the manifest edition.")
    if not runtime_identity:
        options = selected_app / "lib" / "firebase_options.dart"
        projects = re.findall(r"\bprojectId\s*:\s*['\"]([^'\"]+)['\"]", options.read_text(encoding="utf-8"))
        if FIREBASE_PROJECTS[firebase_target] not in projects:
            raise ValueError("Selected Firebase project is not configured in the app's public Firebase options.")

    source_hashes = {}
    for relative in SOURCE_FILES:
        source = repo_root / relative
        if not source.is_file():
            raise FileNotFoundError(f"Required release input is missing: {relative.as_posix()}")
        source_hashes[relative.as_posix()] = sha256_file(source)
    configuration_files = configuration_hashes(repo_root, selected_app, platform, runtime_identity)
    configuration_revision = hashlib.sha256(
        json.dumps(configuration_files, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()

    version = {
        "commit": commit_id,
        "worktree_dirty": is_dirty,
        "source_revision_status": "dirty-working-tree" if is_dirty else "clean-commit",
        "configuration_revision": configuration_revision,
        "platform": platform,
        "target": firebase_target,
        "firebase_project_id": FIREBASE_PROJECTS[firebase_target],
        "app": app,
        "edition": edition,
    }
    version_path = build_dir / "version.json"
    existing_version = {}
    if version_path.exists():
        try:
            loaded_version = json.loads(version_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise ValueError("Existing version.json is unreadable or invalid; refusing to replace it.") from error
        if not isinstance(loaded_version, dict):
            raise ValueError("Existing version.json must contain an object; refusing to replace it.")
        existing_version = loaded_version
    merged_version = {**existing_version, **version}
    _write_json(version_path, merged_version)
    manifest = {
        "commit": commit_id,
        "worktree_dirty": is_dirty,
        "source_revision_status": "dirty-working-tree" if is_dirty else "clean-commit",
        "platform": platform,
        "target": firebase_target,
        "firebase_project_id": FIREBASE_PROJECTS[firebase_target],
        "app": app,
        "edition": edition,
        "build_defines": build_defines,
        "files": _output_hashes(build_dir),
        "source_files": dict(sorted(source_hashes.items())),
        "configuration_files": configuration_files,
        "configuration_revision": configuration_revision,
        "minimum_supported_app_version": minimum,
        "created_at_utc": created_text,
    }
    _write_json(build_dir / "release-manifest.json", manifest)
    return manifest


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=MANIFEST_HELP)
    parser.add_argument("--repo-root", type=Path, required=True)
    parser.add_argument("--build-dir", type=Path, required=True)
    parser.add_argument("--platform", choices=("web", "android"), required=True)
    parser.add_argument("--firebase-target", choices=tuple(FIREBASE_PROJECTS), required=True)
    parser.add_argument("--app", choices=("admin", "mobile"), required=True)
    parser.add_argument("--edition", choices=("basic", "advanced", "runtime"), required=True)
    parser.add_argument("--app-dir", type=Path)
    parser.add_argument("--minimum-supported-app-version")
    parser.add_argument("--define", action="append", default=[])
    args = parser.parse_args(argv)
    try:
        manifest = create_release_metadata(
            repo_root=args.repo_root,
            build_dir=args.build_dir,
            platform=args.platform,
            firebase_target=args.firebase_target,
            app=args.app,
            edition=args.edition,
            defines=args.define,
            minimum_supported_app_version=args.minimum_supported_app_version,
            app_dir=args.app_dir,
        )
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"release manifest error: {error}", file=sys.stderr)
        return 2
    print(f"Wrote {args.build_dir / 'release-manifest.json'} for commit {manifest['commit']}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
