"""Validate base builds against split APK codes, not the base alone."""
from contextlib import redirect_stdout
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from release_metadata import (
    android_split_version_codes,
    android_distribution_version_code,
    validate_android_distribution_version_code,
    main,
    validate_android_version_code,
)
from validate_android_cores import CoreValidationError


class AndroidUpdateVersionTest(unittest.TestCase):
    def test_rejects_older_and_same_public_split_builds(self):
        for number in (120, 121):
            with self.subTest(number=number), self.assertRaisesRegex(ValueError, "2121"):
                validate_android_version_code(number)

    def test_historical_127_is_an_upgrade_from_public_121(self):
        self.assertEqual(
            validate_android_version_code(127),
            {"arm64-v8a": 2127, "x86_64": 4127},
        )
        # A base equal to the old arm64 APK code is not the same APK code.
        self.assertEqual(
            validate_android_version_code(2121),
            {"arm64-v8a": 4121, "x86_64": 6121},
        )

    def test_frozen_r4_matches_verified_apk_badging(self):
        self.assertEqual(
            validate_android_version_code(2122),
            {"arm64-v8a": 4122, "x86_64": 6122},
        )

    def test_explicit_r4_baseline_prevents_reset_and_requires_next_build(self):
        r4_codes = {"arm64-v8a": 4122, "x86_64": 6122}
        for number in (127, 2122):
            with self.subTest(number=number), self.assertRaisesRegex(ValueError, "4122"):
                validate_android_version_code(number, previous_codes=r4_codes)
        self.assertEqual(
            validate_android_version_code(2123, previous_codes=r4_codes),
            {"arm64-v8a": 4123, "x86_64": 6123},
        )

    def test_x64_baseline_is_checked_even_when_arm64_can_upgrade(self):
        baseline = {"arm64-v8a": 2121, "x86_64": 4127}
        with self.assertRaisesRegex(ValueError, "x86_64.*must exceed.*4127"):
            validate_android_version_code(127, previous_codes=baseline)

    def test_rejects_android_distribution_limit(self):
        self.assertEqual(
            android_split_version_codes(2_099_996_000),
            {"arm64-v8a": 2_099_998_000, "x86_64": 2_100_000_000},
        )
        # Both bases fit the old scalar limit, but the x64 APK would exceed it.
        for number in (2_099_996_001, 2_100_000_000):
            with self.subTest(number=number), self.assertRaisesRegex(ValueError, "limit"):
                validate_android_version_code(number)

    def test_base_must_be_a_positive_integer(self):
        for number in (0, -1, True, 127.0, "127"):
            with self.subTest(number=number), self.assertRaisesRegex(ValueError, "positive integer"):
                android_split_version_codes(number)

    def test_baseline_cannot_leave_an_abi_unchecked_or_use_invalid_codes(self):
        for baseline in (
            {},
            {"arm64-v8a": 2121},
            {"arm64-v8a": 2121, "x86_64": 4121, "unknown": 1},
            {"arm64-v8a": 2121, "x86_64": 0},
            {"arm64-v8a": True, "x86_64": 4121},
            {"arm64-v8a": 2121, "x86_64": 2_100_000_001},
        ):
            with self.subTest(baseline=baseline), self.assertRaises(ValueError):
                validate_android_version_code(127, previous_codes=baseline)

    def test_entrypoint_blocks_downgrade_before_native_or_git_work(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "pubspec.yaml").write_text("version: 1.2.0+0\n")
            with mock.patch("release_metadata.validate_installed") as native, \
                    mock.patch("release_metadata.subprocess.check_output") as git:
                with self.assertRaisesRegex(SystemExit, "positive integer"):
                    main(root)
                native.assert_not_called()
                git.assert_not_called()

    def test_entrypoint_reports_base_and_expected_codes_without_changing_ci_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "pubspec.yaml").write_text("version: 1.2.0+2129\n")
            for abi in ("armeabi-v7a", "arm64-v8a", "x86_64"):
                libraries = root / "android/app/src/main/jniLibs" / abi
                libraries.mkdir(parents=True)
                for name in ("libsingbox.so", "libtun2socks.so"):
                    (libraries / name).touch()
            output = root / "github-output"
            console = io.StringIO()
            # Core integrity and Git checks have their own tests; isolate this
            # entrypoint's version check and existing GitHub output contract.
            with mock.patch("release_metadata.load_manifest", return_value={}), \
                    mock.patch("release_metadata.validate_installed"), \
                    mock.patch("release_metadata.subprocess.check_output", return_value=""), \
                    mock.patch.dict("os.environ", {"GITHUB_REF": "", "GITHUB_OUTPUT": str(output)}), \
                    redirect_stdout(console):
                main(root)
            self.assertIn("base build 2129", console.getvalue())
            self.assertIn("armeabi-v7a=12129, arm64-v8a=12129, x86_64=12129", console.getvalue())
            self.assertEqual(output.read_text(), "version=1.2.0\n")


class SharedAndroidDistributionCodeTest(unittest.TestCase):
    def test_current_universal_and_play_use_one_code_above_legacy(self):
        self.assertEqual(validate_android_distribution_version_code(2129), 12129)
        self.assertGreater(android_distribution_version_code(2129), 6129)

    def test_historical_base_reset_is_rejected_by_release_and_gradle(self):
        for number in (121, 127, 2128):
            with self.subTest(number=number), self.assertRaisesRegex(ValueError, "at least 2129"):
                validate_android_distribution_version_code(number)
        gradle = (Path(__file__).resolve().parents[2] / "android/app/build.gradle.kts").read_text()
        self.assertIn("require(honeyBaseBuild >= 2129L", gradle)
        self.assertIn("versionCode = honeyDistributionCode.toInt()", gradle)

    def test_gradle_rejects_split_builds_before_artifact_configuration(self):
        gradle = (Path(__file__).resolve().parents[2] / "android/app/build.gradle.kts").read_text()
        rejection = 'require(project.findProperty("split-per-abi")?.toString()?.toBoolean() != true)'
        self.assertLess(gradle.index(rejection), gradle.index("android {"))
        self.assertIn("remove --split-per-abi", gradle)
        # The failed late override must never return: AGP has already locked the
        # output property, and early modern callbacks are overwritten by this SDK.
        self.assertNotIn("afterEvaluate", gradle)
        self.assertNotIn("versionCodeOverride", gradle)
        self.assertNotIn("applicationVariants", gradle)

    def test_next_build_upgrades_every_previous_artifact_format(self):
        previous = {abi: 12129 for abi in ("armeabi-v7a", "arm64-v8a", "x86_64")}
        self.assertEqual(validate_android_distribution_version_code(2130, previous_codes=previous), 12130)
        for number in (2129,):
            with self.assertRaisesRegex(ValueError, "must exceed"):
                validate_android_distribution_version_code(number, previous_codes=previous)

    def test_shared_code_limit_and_invalid_types(self):
        self.assertEqual(android_distribution_version_code(2_099_990_000), 2_100_000_000)
        for number in (0, -1, True, 1.5, "2129", 2_099_990_001):
            with self.assertRaises(ValueError):
                android_distribution_version_code(number)

    def test_baseline_must_cover_three_abis_and_use_actual_integer_codes(self):
        for previous in ({}, {"arm64-v8a": 4129},
                         {"armeabi-v7a": 1121, "arm64-v8a": True, "x86_64": 4121}):
            with self.assertRaises(ValueError):
                validate_android_distribution_version_code(2129, previous_codes=previous)


class PlatformReleaseMetadataTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.manifest = json.loads(
            (Path(__file__).resolve().parents[2] / "core-lock.json").read_text()
        )
        (self.root / "core-lock.json").write_text(json.dumps(self.manifest))
        (self.root / "pubspec.yaml").write_text("version: 1.2.0+2129\n")

    def test_windows_accepts_valid_manifest_without_prepared_android_files(self):
        console = io.StringIO()
        output = self.root / "github-output"
        with mock.patch("release_metadata.validate_installed") as native, \
                mock.patch("release_metadata.subprocess.check_output", return_value="") as git, \
                mock.patch.dict("os.environ", {"GITHUB_REF": "", "GITHUB_OUTPUT": str(output)}), \
                redirect_stdout(console):
            main(self.root, platform="windows")
        native.assert_not_called()
        git.assert_called_once_with(["git", "ls-files"], cwd=self.root, text=True)
        self.assertFalse((self.root / "android").exists())
        self.assertEqual(
            console.getvalue(),
            "Release candidate: v1.2.0, base build 2129; "
            "Windows release metadata and core manifest validated\n",
        )
        self.assertNotIn("native cores present", console.getvalue())
        self.assertEqual(output.read_text(), "version=1.2.0\n")

    def test_default_all_and_android_still_require_both_prepared_abis(self):
        for platform in (None, "all", "android"):
            with self.subTest(platform=platform), \
                    mock.patch("release_metadata.validate_installed") as native, \
                    mock.patch("release_metadata.subprocess.check_output") as git, \
                    mock.patch.dict("os.environ", {"GITHUB_REF": ""}):
                with self.assertRaisesRegex(SystemExit, "Missing native VPN library"):
                    if platform is None:
                        main(self.root)
                    else:
                        main(self.root, platform=platform)
                native.assert_not_called()
                git.assert_not_called()

    def test_all_and_android_still_validate_actual_native_integrity(self):
        for abi in ("armeabi-v7a", "arm64-v8a", "x86_64"):
            libraries = self.root / "android/app/src/main/jniLibs" / abi
            libraries.mkdir(parents=True)
            for name in ("libsingbox.so", "libtun2socks.so"):
                (libraries / name).touch()
        for platform in ("all", "android"):
            with self.subTest(platform=platform), \
                    mock.patch("release_metadata.subprocess.check_output") as git, \
                    mock.patch.dict("os.environ", {"GITHUB_REF": ""}):
                with self.assertRaisesRegex(CoreValidationError, "size|SHA-256"):
                    main(self.root, platform=platform)
                git.assert_not_called()

    def test_windows_rejects_invalid_core_manifest(self):
        for change in ("schema", "asset"):
            manifest = json.loads(json.dumps(self.manifest))
            if change == "schema":
                manifest["schema_version"] = 2
            else:
                manifest["sing_box"]["assets"]["windows-amd64"]["unreviewed"] = True
            (self.root / "core-lock.json").write_text(json.dumps(manifest))
            with self.subTest(change=change), \
                    mock.patch("release_metadata.validate_installed") as native, \
                    mock.patch("release_metadata.subprocess.check_output") as git, \
                    mock.patch.dict("os.environ", {"GITHUB_REF": ""}):
                with self.assertRaises(ValueError):
                    main(self.root, platform="windows")
                native.assert_not_called()
                git.assert_not_called()

    def test_windows_still_rejects_tracked_signing_keystores(self):
        for filename in ("android/release.jks", "android/release.keystore.backup"):
            with self.subTest(filename=filename), \
                    mock.patch("release_metadata.subprocess.check_output", return_value=filename), \
                    mock.patch.dict("os.environ", {"GITHUB_REF": ""}):
                with self.assertRaisesRegex(SystemExit, "keystores must not be tracked"):
                    main(self.root, platform="windows")

    def test_windows_still_rejects_bad_version_build_and_tag(self):
        for pubspec, tag, reason in (
            ("version: invalid\n", "", "semantic version"),
            ("version: 1.2.0+0\n", "", "positive integer"),
            ("version: 1.2.0+2129\n", "refs/tags/v1.2.1", "does not match"),
        ):
            (self.root / "pubspec.yaml").write_text(pubspec)
            with self.subTest(pubspec=pubspec, tag=tag), \
                    mock.patch("release_metadata.load_manifest") as manifest, \
                    mock.patch("release_metadata.subprocess.check_output") as git, \
                    mock.patch.dict("os.environ", {"GITHUB_REF": tag}):
                with self.assertRaisesRegex(SystemExit, reason):
                    main(self.root, platform="windows")
                manifest.assert_not_called()
                git.assert_not_called()

    def test_unknown_platform_cannot_disable_checks(self):
        for platform in ("macos", "WINDOWS", "", None, []):
            with self.subTest(platform=platform), \
                    mock.patch("release_metadata.load_manifest") as manifest, \
                    mock.patch("release_metadata.subprocess.check_output") as git:
                with self.assertRaisesRegex(SystemExit, "platform must be"):
                    main(self.root, platform=platform)
                manifest.assert_not_called()
                git.assert_not_called()


if __name__ == "__main__":
    unittest.main()
