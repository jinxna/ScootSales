import os
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ANDROID = ROOT / "flutter_mobile_app" / "android"
GRADLE = ANDROID / ("gradlew.bat" if os.name == "nt" else "gradlew")
FLUTTER_SDK_LOCATION = ANDROID / "local.properties"


def gradle_dry_run(*tasks, ci=None, unsigned=False):
    env = os.environ.copy()
    env.pop("ORG_GRADLE_PROJECT_ciUnsignedRelease", None)
    env.pop("ciUnsignedRelease", None)
    env.pop("CI", None)
    if ci is not None:
        env["CI"] = ci
    if unsigned:
        env["ORG_GRADLE_PROJECT_ciUnsignedRelease"] = "true"
    return subprocess.run(
        [str(GRADLE), "--offline", "--console=plain", "--dry-run", *tasks],
        cwd=ANDROID,
        env=env,
        capture_output=True,
        text=True,
        timeout=180,
        check=False,
    )


@unittest.skipUnless(
    GRADLE.is_file() and FLUTTER_SDK_LOCATION.is_file(),
    "Needs the Gradle wrapper and the local.properties that flutter pub get writes",
)
class ReleaseTaskGraphGuardTests(unittest.TestCase):
    def test_abbreviated_release_task_is_rejected_before_task_execution(self):
        result = gradle_dry_run(":app:assembleRel")
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertIn("full release task name", output.lower())

    def test_aggregate_build_cannot_reach_release_without_loaded_signing_config(self):
        result = gradle_dry_run(":app:build")
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertIn("full release task name", output.lower())

    def test_debug_task_graph_does_not_require_release_signing(self):
        result = gradle_dry_run(":app:assembleDebug")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_explicit_unsigned_release_flag_works_only_in_ci(self):
        local = gradle_dry_run(":app:assembleRelease", unsigned=True)
        self.assertNotEqual(local.returncode, 0)
        self.assertIn("only when CI=true", (local.stdout + local.stderr))

        ci = gradle_dry_run(":app:assembleRelease", ci="true", unsigned=True)
        self.assertEqual(ci.returncode, 0, ci.stdout + ci.stderr)

    def test_ci_unsigned_flag_allows_aggregate_graph_to_include_release(self):
        result = gradle_dry_run(":app:build", ci="true", unsigned=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
