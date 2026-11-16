import json
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import release_manifest


class ReleaseManifestTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.build = self.root / "flutter_mobile_app" / "build" / "web_e2e"
        self.build.mkdir(parents=True)
        (self.root / "flutter_mobile_app" / "pubspec.yaml").write_text(
            "version: 1.4.2+8\n", encoding="utf-8"
        )
        (self.root / "admin_dashboard").mkdir()
        (self.root / "admin_dashboard" / "firestore.rules").write_text(
            "rules fixture\n", encoding="utf-8"
        )
        (self.root / "admin_dashboard" / "firestore.indexes.json").write_text(
            '{"indexes":[]}\n', encoding="utf-8"
        )
        (self.root / "e2e").mkdir()
        (self.root / "e2e" / "build.cjs").write_text("build config\n", encoding="utf-8")
        (self.root / "flutter_mobile_app" / "lib").mkdir()
        (self.root / "flutter_mobile_app" / "lib" / "firebase_options.dart").write_text(
            "projectId: 'cos40005'\n", encoding="utf-8"
        )
        (self.build / "index.html").write_text("built page\n", encoding="utf-8")
        self.timestamp = datetime(2026, 10, 28, tzinfo=timezone.utc)

    def tearDown(self):
        self.temp.cleanup()

    def create(self, **overrides):
        args = {
            "repo_root": self.root,
            "build_dir": self.build,
            "platform": "web",
            "firebase_target": "supermarket",
            "app": "mobile",
            "edition": "advanced",
            "defines": [
                "USE_FIREBASE_EMULATOR=true",
                "FIREBASE_EMULATOR_HOST=127.0.0.1",
                "FIRESTORE_EMULATOR_PORT=8089",
                "EDITION=advanced",
                "FIREBASE_TARGET=supermarket",
                "COPILOT_URL=http://127.0.0.1:18765",
                "FORECAST_API=http://127.0.0.1:18766",
                "API_TOKEN=must-not-be-written",
            ],
            "commit": "a" * 40,
            "worktree_dirty": False,
            "now": self.timestamp,
        }
        args.update(overrides)
        return release_manifest.create_release_metadata(**args)

    def test_version_and_manifest_share_commit_and_capture_release_identity(self):
        manifest = self.create()
        version = json.loads((self.build / "version.json").read_text(encoding="utf-8"))
        self.assertEqual(version["commit"], "a" * 40)
        self.assertEqual(manifest["commit"], version["commit"])
        self.assertEqual(manifest["platform"], "web")
        self.assertEqual(manifest["target"], "supermarket")
        self.assertEqual(manifest["firebase_project_id"], "cos40005")
        self.assertFalse(manifest["worktree_dirty"])
        self.assertEqual(manifest["app"], "mobile")
        self.assertEqual(manifest["edition"], "advanced")
        self.assertEqual(manifest["minimum_supported_app_version"], "1.4.2")
        self.assertEqual(manifest["created_at_utc"], "2026-10-28T00:00:00Z")

    def test_version_json_preserves_flutter_fields_and_refreshes_release_metadata(self):
        version_path = self.build / "version.json"
        sdk_fields = {
            "version": "1.4.2",
            "build_number": "8",
            "app_name": "Field Sales",
            "package_name": "my.scootsales.app",
            "frameworkVersion": "3.x",
            "commit": "old-commit",
            "target": "hardware",
            "edition": "basic",
        }
        version_path.write_text(json.dumps(sdk_fields), encoding="utf-8")

        self.create()

        version = json.loads(version_path.read_text(encoding="utf-8"))
        for key in ("version", "build_number", "app_name", "package_name", "frameworkVersion"):
            self.assertEqual(version[key], sdk_fields[key])
        self.assertEqual(version["commit"], "a" * 40)
        self.assertEqual(version["target"], "supermarket")
        self.assertEqual(version["platform"], "web")
        self.assertEqual(version["edition"], "advanced")

    def test_invalid_existing_version_json_is_not_overwritten(self):
        version_path = self.build / "version.json"
        original = "not-json"
        version_path.write_text(original, encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "version.json"):
            self.create()
        self.assertEqual(version_path.read_text(encoding="utf-8"), original)

    def test_hashes_build_files_and_rules_inputs_but_not_manifest_itself(self):
        nested = self.build / "assets" / "app.js"
        nested.parent.mkdir()
        nested.write_bytes(b"asset bytes")
        manifest = self.create()
        self.assertEqual(
            manifest["files"]["assets/app.js"],
            release_manifest.sha256_file(nested),
        )
        self.assertIn("version.json", manifest["files"])
        self.assertNotIn("release-manifest.json", manifest["files"])
        self.assertIn("admin_dashboard/firestore.rules", manifest["source_files"])
        self.assertIn("admin_dashboard/firestore.indexes.json", manifest["source_files"])

    def test_only_allowlisted_safe_defines_are_recorded(self):
        manifest = self.create()
        self.assertEqual(
            manifest["build_defines"],
            {
                "USE_FIREBASE_EMULATOR": "true",
                "FIREBASE_EMULATOR_HOST": "127.0.0.1",
                "FIRESTORE_EMULATOR_PORT": "8089",
                "EDITION": "advanced",
                "FIREBASE_TARGET": "supermarket",
                "COPILOT_URL": "http://127.0.0.1:18765",
                "FORECAST_API": "http://127.0.0.1:18766",
            },
        )
        self.assertNotIn("API_TOKEN", json.dumps(manifest))

    def test_rejects_invalid_safe_define_values(self):
        with self.assertRaisesRegex(ValueError, "FIRESTORE_EMULATOR_PORT"):
            self.create(defines=["FIRESTORE_EMULATOR_PORT=secret"])
        safe = [
            "EDITION=advanced",
            "FIREBASE_TARGET=supermarket",
            "COPILOT_URL=http://127.0.0.1:18765?token=unsafe",
        ]
        with self.assertRaisesRegex(ValueError, "COPILOT_URL"):
            self.create(defines=safe)

    def test_accepts_credential_free_https_service_origins_and_nondefault_ports(self):
        defines = [
            "USE_FIREBASE_EMULATOR=true",
            "FIREBASE_EMULATOR_HOST=127.0.0.1",
            "FIRESTORE_EMULATOR_PORT=8089",
            "FIREBASE_AUTH_EMULATOR_PORT=9099",
            "EDITION=advanced",
            "FIREBASE_TARGET=supermarket",
            "COPILOT_URL=https://voice.example.test:8443",
            "FORECAST_API=https://forecast.example.test",
        ]
        manifest = self.create(defines=defines)
        self.assertEqual(manifest["build_defines"]["COPILOT_URL"], "https://voice.example.test:8443")
        self.assertEqual(manifest["build_defines"]["FORECAST_API"], "https://forecast.example.test")

    def test_https_service_origins_reject_userinfo_query_fragment_and_paths(self):
        invalid_urls = (
            "https://user@voice.example.test",
            "https://voice.example.test/?token=value",
            "https://voice.example.test/#fragment",
            "https://voice.example.test/api",
        )
        base = [
            "USE_FIREBASE_EMULATOR=true",
            "FIREBASE_EMULATOR_HOST=127.0.0.1",
            "FIRESTORE_EMULATOR_PORT=8089",
            "FIREBASE_AUTH_EMULATOR_PORT=9099",
            "EDITION=advanced",
            "FIREBASE_TARGET=supermarket",
            "FORECAST_API=https://forecast.example.test",
        ]
        for url in invalid_urls:
            with self.subTest(url=url), self.assertRaisesRegex(ValueError, "COPILOT_URL"):
                self.create(defines=[*base, f"COPILOT_URL={url}"])

    def test_rejects_missing_build_directory_and_missing_source_inputs(self):
        with self.assertRaisesRegex(FileNotFoundError, "build directory"):
            self.create(build_dir=self.build / "missing")
        (self.root / "admin_dashboard" / "firestore.rules").unlink()
        with self.assertRaisesRegex(FileNotFoundError, "firestore.rules"):
            self.create()

    def test_rejects_unsupported_release_identity_and_bad_minimum_version(self):
        for values in (
            {"platform": "unknown"},
            {"firebase_target": "unknown"},
            {"app": "hardware"},
            {"edition": "preview"},
            {"minimum_supported_app_version": "not-a-version"},
        ):
            with self.subTest(values=values), self.assertRaises(ValueError):
                self.create(**values)

    def test_rejects_symlinks_without_hashing_any_files(self):
        outside = self.root / "private.txt"
        outside.write_text("not a build artifact", encoding="utf-8")
        link = self.build / "linked.txt"
        try:
            link.symlink_to(outside)
        except (OSError, NotImplementedError):
            self.skipTest("symlinks are not available in this environment")
        with patch.object(release_manifest, "sha256_file") as hash_file:
            with self.assertRaisesRegex(ValueError, "symlink"):
                self.create()
            hash_file.assert_not_called()

    def test_rejects_repo_and_qa_roots_but_allows_dedicated_qa_build_child(self):
        with self.assertRaisesRegex(ValueError, "selected app build or dedicated QA build"):
            self.create(build_dir=self.root)
        qa_root = self.root / "qa_artifacts" / "p3-release-ops"
        qa_root.mkdir(parents=True)
        with self.assertRaisesRegex(ValueError, "selected app build or dedicated QA build"):
            self.create(build_dir=qa_root)
        qa_build = qa_root / "builds" / "manifest-fixture"
        qa_build.mkdir(parents=True)
        self.create(build_dir=qa_build)

    def test_sensitive_output_names_fail_before_hashing(self):
        forbidden_names = (
            ".env.fixture",
            "settings.env.local",
            "serviceAccountKey.fixture.json",
            "fixture.jks",
            "fixture.keystore",
        )
        for filename in forbidden_names:
            with self.subTest(filename=filename):
                fixture = self.build / filename
                fixture.write_text("synthetic non-secret fixture", encoding="utf-8")
                try:
                    with patch.object(release_manifest, "sha256_file") as hash_file:
                        with self.assertRaisesRegex(ValueError, "sensitive filename"):
                            self.create()
                        hash_file.assert_not_called()
                finally:
                    fixture.unlink(missing_ok=True)

    def test_requires_git_commit_when_not_supplied(self):
        with patch.object(release_manifest, "git_commit", side_effect=RuntimeError("git unavailable")):
            with self.assertRaisesRegex(RuntimeError, "git unavailable"):
                self.create(commit=None)

    def test_dirty_worktree_is_marked_and_configuration_revision_is_recorded(self):
        manifest = self.create(worktree_dirty=True)
        self.assertTrue(manifest["worktree_dirty"])
        self.assertEqual(len(manifest["configuration_revision"]), 64)
        self.assertIn("e2e/build.cjs", manifest["configuration_files"])
        self.assertIn(
            "flutter_mobile_app/lib/firebase_options.dart",
            manifest["configuration_files"],
        )

    def test_android_configuration_revision_includes_gradle_signing_config(self):
        gradle = self.root / "flutter_mobile_app" / "android" / "app"
        gradle.mkdir(parents=True)
        (gradle / "build.gradle.kts").write_text("android config\n", encoding="utf-8")
        manifest = self.create(platform="android")
        self.assertIn(
            "flutter_mobile_app/android/app/build.gradle.kts",
            manifest["configuration_files"],
        )

    def test_shared_dashboard_has_runtime_identity_without_static_firebase_options(self):
        admin = self.root / "admin_dashboard"
        build = admin / "build" / "web_e2e"
        build.mkdir(parents=True)
        (build / "index.html").write_text("shared dashboard\n", encoding="utf-8")
        (admin / "pubspec.yaml").write_text("version: 2.1.0+1\n", encoding="utf-8")
        app = admin / "lib" / "app"
        app.mkdir(parents=True)
        (app / "workspace_runtime.dart").write_text("signed workspace startup\n", encoding="utf-8")
        envelope = self.root / "packages" / "scoot_directory_client" / "lib" / "src"
        envelope.mkdir(parents=True)
        (envelope / "signed_envelope.dart").write_text("record verifier\n", encoding="utf-8")
        manifest = self.create(
            app="admin", build_dir=build, firebase_target="runtime", edition="runtime",
            defines=["PLATFORM_API_URL=http://127.0.0.1:18790"],
        )
        self.assertEqual(manifest["target"], "runtime")
        self.assertIsNone(manifest["firebase_project_id"])
        self.assertEqual(manifest["edition"], "runtime")
        self.assertEqual(manifest["minimum_supported_app_version"], "1.4.2")
        self.assertIn("admin_dashboard/lib/app/workspace_runtime.dart", manifest["configuration_files"])
        self.assertEqual(manifest["build_defines"]["PLATFORM_API_URL"], "http://127.0.0.1:18790")
        with self.assertRaisesRegex(ValueError, "runtime"):
            self.create(app="admin", build_dir=build, firebase_target="runtime", edition="runtime",
                        defines=["EDITION=basic", "FIREBASE_TARGET=supermarket"])

    def test_alternate_mobile_root_is_explicit_and_confined_to_repository(self):
        alternate = self.root / "alternate mobile"
        build = alternate / "build" / "web_e2e"
        build.mkdir(parents=True)
        (build / "index.html").write_text("alternate build\n", encoding="utf-8")
        (alternate / "pubspec.yaml").write_text("version: 3.2.1+1\n", encoding="utf-8")
        (alternate / "lib").mkdir()
        (alternate / "lib" / "firebase_options.dart").write_text("projectId: 'hardware-client-sales'\n", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "project"):
            self.create(build_dir=build, app_dir="alternate mobile")
        manifest = self.create(
            build_dir=build, app_dir="alternate mobile", firebase_target="hardware",
            defines=["FIREBASE_TARGET=hardware", "EDITION=advanced"],
        )
        self.assertEqual(manifest["minimum_supported_app_version"], "3.2.1")
        self.assertIn("alternate mobile/pubspec.yaml", manifest["configuration_files"])
        with self.assertRaisesRegex(ValueError, "inside the repository"):
            self.create(app_dir=self.root.parent)

    def test_public_key_ids_match_directory_verifiers(self):
        base = ["FIREBASE_TARGET=supermarket", "EDITION=advanced"]
        value = f"prod.2026-10={'A' * 43}"
        manifest = self.create(defines=[*base, f"PLATFORM_PUBLIC_KEYS={value}"])
        self.assertEqual(manifest["build_defines"]["PLATFORM_PUBLIC_KEYS"], value)
        for key_id in ("UPPER", "-leading", "x" * 65):
            with self.subTest(key_id=key_id), self.assertRaisesRegex(ValueError, "PLATFORM_PUBLIC_KEYS"):
                self.create(defines=[*base, f"PLATFORM_PUBLIC_KEYS={key_id}={'A' * 43}"])

    def test_company_lookup_provenance_keeps_only_public_endpoint_and_keys(self):
        base = ["FIREBASE_TARGET=supermarket", "EDITION=advanced"]
        endpoint = "http://127.0.0.1:18790/v1/companies"
        keys = f"e2e-1={'A' * 43}"
        manifest = self.create(defines=[*base, f"COMPANY_LOOKUP_URL={endpoint}", f"COMPANY_REGISTRY_KEYS={keys}"])
        self.assertEqual(manifest["build_defines"]["COMPANY_LOOKUP_URL"], endpoint)
        self.assertEqual(manifest["build_defines"]["COMPANY_REGISTRY_KEYS"], keys)
        https_endpoint = "https://directory.example/v1/companies"
        manifest = self.create(defines=[*base, f"COMPANY_LOOKUP_URL={https_endpoint}"])
        self.assertEqual(manifest["build_defines"]["COMPANY_LOOKUP_URL"], https_endpoint)
        for url in (
            "http://public.example/v1/companies",
            "http://localhost/v1/companies",
            "https://directory.example:/v1/companies",
            "https://u:p@directory.example/v1/companies",
            "https://directory.example/v1/companies?token=private",
            "https://directory.example/v1/companies#fragment",
            "https://directory.example/v1/companies ",
            "https://directory.example/private-token",
        ):
            with self.subTest(url=url), self.assertRaisesRegex(ValueError, "COMPANY_LOOKUP_URL"):
                self.create(defines=[*base, f"COMPANY_LOOKUP_URL={url}"])
        for value in (f"UPPER={'A' * 43}", f"registry={'A' * 64}"):
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "COMPANY_REGISTRY_KEYS"):
                self.create(defines=[*base, f"COMPANY_REGISTRY_KEYS={value}"])


if __name__ == "__main__":
    unittest.main()
