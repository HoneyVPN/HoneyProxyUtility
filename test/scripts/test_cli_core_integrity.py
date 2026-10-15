"""Reject corrupt CLI packages before replacing a previously verified core."""
import copy
import hashlib
import io
import json
from pathlib import Path
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import warnings
import zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import core_manifest
import prepare_cli_core


PAYLOAD = b"synthetic executable fixture; never executed"


def zip_package(directory, entries, member="package/sing-box.exe"):
    path = directory / "core.zip"
    with zipfile.ZipFile(path, "w") as archive:
        for name, data, mode in entries:
            item = zipfile.ZipInfo(name)
            item.external_attr = mode << 16
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", UserWarning)
                archive.writestr(item, data)
    return path, {"archive_member": member, "archive_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                  "installed_sha256": hashlib.sha256(PAYLOAD).hexdigest(), "runtime_assets": []}


def tar_package(directory, entries, member="package/sing-box"):
    path = directory / "core.tar.gz"
    with tarfile.open(path, "w:gz") as archive:
        for name, data, kind in entries:
            item = tarfile.TarInfo(name)
            item.type = kind
            if kind == tarfile.REGTYPE:
                item.size = len(data)
                archive.addfile(item, io.BytesIO(data))
            else:
                item.linkname = "../outside"
                archive.addfile(item)
    return path, {"archive_member": member, "archive_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                  "installed_sha256": hashlib.sha256(PAYLOAD).hexdigest(), "runtime_assets": []}


class CliArchiveIntegrityTests(unittest.TestCase):
    def test_exact_zip_and_tar_member_read_without_extracting_other_files(self):
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            archive, asset = zip_package(directory, [("package/sing-box.exe", PAYLOAD, stat.S_IFREG), ("package/LICENSE", b"license", stat.S_IFREG)])
            self.assertEqual(prepare_cli_core.checked_binary(archive, asset), PAYLOAD)
            archive, asset = tar_package(directory, [("package/sing-box", PAYLOAD, tarfile.REGTYPE), ("package/LICENSE", b"license", tarfile.REGTYPE)])
            self.assertEqual(prepare_cli_core.checked_binary(archive, asset), PAYLOAD)
            self.assertFalse((directory / "package").exists())

    def test_archive_corruption_and_wrong_executable_hash_rejected(self):
        with tempfile.TemporaryDirectory() as name:
            archive, asset = zip_package(Path(name), [("package/sing-box.exe", PAYLOAD, stat.S_IFREG)])
            wrong = dict(asset, archive_sha256="0" * 64)
            with self.assertRaisesRegex(ValueError, "archive checksum"):
                prepare_cli_core.checked_binary(archive, wrong)
            wrong = dict(asset, installed_sha256="0" * 64)
            with self.assertRaisesRegex(ValueError, "binary checksum"):
                prepare_cli_core.checked_binary(archive, wrong)

    def test_reviewed_archive_and_executable_sizes_must_match(self):
        with tempfile.TemporaryDirectory() as name:
            archive, asset = zip_package(Path(name), [("package/sing-box.exe", PAYLOAD, stat.S_IFREG)])
            for wrong, message in ((dict(asset, archive_bytes=archive.stat().st_size + 1), "archive size"), (dict(asset, installed_bytes=len(PAYLOAD) + 1), "binary size")):
                with self.assertRaisesRegex(ValueError, message):
                    prepare_cli_core.checked_binary(archive, wrong)

    def test_locked_traversal_and_absolute_member_rejected(self):
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            for member in ("../outside/sing-box.exe", "/outside/sing-box.exe", "..\\outside\\sing-box.exe"):
                archive, asset = zip_package(directory, [(member, PAYLOAD, stat.S_IFREG)], member)
                with self.assertRaisesRegex(ValueError, "Unsafe"):
                    prepare_cli_core.checked_binary(archive, asset)

    def test_zip_symbolic_link_and_tar_symbolic_hard_links_rejected(self):
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            archive, asset = zip_package(directory, [("package/sing-box.exe", PAYLOAD, stat.S_IFLNK)])
            with self.assertRaisesRegex(ValueError, "regular binary"):
                prepare_cli_core.checked_binary(archive, asset)
            for kind in (tarfile.SYMTYPE, tarfile.LNKTYPE):
                archive, asset = tar_package(directory, [("package/sing-box", PAYLOAD, kind)])
                with self.assertRaisesRegex(ValueError, "regular binary"):
                    prepare_cli_core.checked_binary(archive, asset)

    def test_duplicate_target_members_are_ambiguous_even_if_last_hash_matches(self):
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            archive, asset = zip_package(directory, [("package/sing-box.exe", b"other", stat.S_IFREG), ("package/sing-box.exe", PAYLOAD, stat.S_IFREG)])
            with self.assertRaises(ValueError):
                prepare_cli_core.checked_binary(archive, asset)
            archive, asset = tar_package(directory, [("package/sing-box", b"other", tarfile.REGTYPE), ("package/sing-box", PAYLOAD, tarfile.REGTYPE)])
            with self.assertRaises(ValueError):
                prepare_cli_core.checked_binary(archive, asset)

    def test_unreviewed_runtime_dependency_rejected(self):
        with tempfile.TemporaryDirectory() as name:
            archive, asset = zip_package(Path(name), [("package/sing-box.exe", PAYLOAD, stat.S_IFREG)])
            asset["runtime_assets"] = ["libcronet.dll"]
            with self.assertRaisesRegex(ValueError, "runtime assets"):
                prepare_cli_core.checked_binary(archive, asset)


class CliPublicationIntegrityTests(unittest.TestCase):
    def preparation_fixture(self, directory, platform="linux-amd64"):
        if platform == "windows-amd64":
            archive, asset = zip_package(directory, [("package/sing-box.exe", PAYLOAD, stat.S_IFREG)])
        else:
            archive, asset = tar_package(directory, [("package/sing-box", PAYLOAD, tarfile.REGTYPE)])
        core = copy.deepcopy(core_manifest.load_manifest()["sing_box"])
        asset = dict(core["assets"][platform], **asset)
        asset.update(archive_bytes=archive.stat().st_size, installed_bytes=len(PAYLOAD))
        core["assets"] = {platform: asset}
        manifest = {"sing_box": core}
        output = directory / "output"
        output.mkdir()
        return archive, manifest, output

    def runtime_output(self, manifest, platform="linux-amd64"):
        metadata = core_manifest.resolve_asset_metadata(manifest["sing_box"], platform)
        return "sing-box version " + metadata["version"] + "\n\nRevision: " + metadata["revision"] + "\n"

    def test_verified_version_published_after_identity_check(self):
        with tempfile.TemporaryDirectory() as name:
            archive, manifest, output = self.preparation_fixture(Path(name))
            destination = output / "sing-box"
            destination.write_bytes(b"previous verified core")

            def runner(command, **kwargs):
                self.assertEqual(destination.read_bytes(), b"previous verified core")
                self.assertEqual(Path(command[0]).read_bytes(), PAYLOAD)
                self.assertNotEqual(Path(command[0]).resolve(), destination.resolve())
                self.assertEqual(command[1:], ["version"])
                return subprocess.CompletedProcess(command, 0, self.runtime_output(manifest), "")

            with patch.object(prepare_cli_core, "load_manifest", return_value=manifest), patch.object(prepare_cli_core.subprocess, "run", side_effect=runner):
                result = prepare_cli_core.prepare("linux-amd64", output, archive)
            self.assertEqual(result, destination)
            self.assertEqual(destination.read_bytes(), PAYLOAD)

    def test_wrong_version_cannot_replace_previous_core_or_publish_a_new_one(self):
        with tempfile.TemporaryDirectory() as name:
            archive, manifest, output = self.preparation_fixture(Path(name))
            destination = output / "sing-box"
            response = subprocess.CompletedProcess([], 0, "sing-box version 1.14.1-extended-2.7.2\n", "")
            for existing in (True, False):
                if existing:
                    destination.write_bytes(b"previous verified core")
                else:
                    destination.unlink(missing_ok=True)
                with patch.object(prepare_cli_core, "load_manifest", return_value=manifest), patch.object(prepare_cli_core.subprocess, "run", return_value=response):
                    with self.assertRaisesRegex(ValueError, "version"):
                        prepare_cli_core.prepare("linux-amd64", output, archive)
                if existing:
                    self.assertEqual(destination.read_bytes(), b"previous verified core")
                else:
                    self.assertFalse(destination.exists())
                self.assertEqual(list(output.iterdir()), [destination] if existing else [])

    def test_failed_version_execution_preserves_existing_core_and_cleans_staging(self):
        with tempfile.TemporaryDirectory() as name:
            archive, manifest, output = self.preparation_fixture(Path(name))
            destination = output / "sing-box"
            destination.write_bytes(b"previous verified core")
            failure = subprocess.CalledProcessError(1, ["fixture", "version"])
            with patch.object(prepare_cli_core, "load_manifest", return_value=manifest), patch.object(prepare_cli_core.subprocess, "run", side_effect=failure):
                with self.assertRaises(subprocess.CalledProcessError):
                    prepare_cli_core.prepare("linux-amd64", output, archive)
            self.assertEqual(destination.read_bytes(), b"previous verified core")
            self.assertEqual(list(output.iterdir()), [destination])

    def test_invalid_archive_never_executes_or_changes_previous_core(self):
        with tempfile.TemporaryDirectory() as name:
            archive, manifest, output = self.preparation_fixture(Path(name))
            manifest["sing_box"]["assets"]["linux-amd64"]["archive_sha256"] = "0" * 64
            destination = output / "sing-box"
            destination.write_bytes(b"previous verified core")
            with patch.object(prepare_cli_core, "load_manifest", return_value=manifest), patch.object(prepare_cli_core.subprocess, "run") as run:
                with self.assertRaises(ValueError):
                    prepare_cli_core.prepare("linux-amd64", output, archive)
            run.assert_not_called()
            self.assertEqual(destination.read_bytes(), b"previous verified core")

    def test_windows_override_is_verified_instead_of_global_default(self):
        with tempfile.TemporaryDirectory() as name:
            archive, manifest, output = self.preparation_fixture(Path(name), "windows-amd64")
            destination = output / "sing-box.exe"
            destination.write_bytes(b"previous verified core")
            self.assertNotEqual(manifest["sing_box"]["version"], manifest["sing_box"]["assets"]["windows-amd64"]["version"])

            def runner(command, **kwargs):
                self.assertEqual(destination.read_bytes(), b"previous verified core")
                self.assertEqual(Path(command[0]).read_bytes(), PAYLOAD)
                self.assertNotEqual(Path(command[0]).resolve(), destination.resolve())
                return subprocess.CompletedProcess(command, 0, self.runtime_output(manifest, "windows-amd64"), "")

            with patch.object(prepare_cli_core, "load_manifest", return_value=manifest), patch.object(prepare_cli_core, "_require_runtime_host"), patch.object(prepare_cli_core.subprocess, "run", side_effect=runner):
                self.assertEqual(prepare_cli_core.prepare("windows-amd64", output, archive), destination)
            self.assertEqual(destination.read_bytes(), PAYLOAD)

    def test_windows_old_version_wrong_revision_and_ambiguous_output_cannot_publish(self):
        with tempfile.TemporaryDirectory() as name:
            archive, manifest, output = self.preparation_fixture(Path(name), "windows-amd64")
            destination = output / "sing-box.exe"
            correct = self.runtime_output(manifest, "windows-amd64")
            wrong_version = correct.replace("1.14.1-extended-2.7.2", manifest["sing_box"]["version"])
            revision = manifest["sing_box"]["assets"]["windows-amd64"]["revision"]
            for text in (wrong_version, correct.replace(revision, "0" * 40), correct.split("Revision:")[0], wrong_version + correct, correct + "Revision: " + revision + "\n"):
                destination.write_bytes(b"previous verified core")
                response = subprocess.CompletedProcess([], 0, text, "")
                with patch.object(prepare_cli_core, "load_manifest", return_value=manifest), patch.object(prepare_cli_core, "_require_runtime_host"), patch.object(prepare_cli_core.subprocess, "run", return_value=response):
                    with self.assertRaisesRegex(ValueError, "version|revision"):
                        prepare_cli_core.prepare("windows-amd64", output, archive)
                self.assertEqual(destination.read_bytes(), b"previous verified core")
                self.assertEqual(list(output.iterdir()), [destination])

    def test_windows_binary_is_never_executed_on_a_non_windows_host(self):
        with tempfile.TemporaryDirectory() as name:
            archive, manifest, output = self.preparation_fixture(Path(name), "windows-amd64")
            with patch.object(prepare_cli_core, "load_manifest", return_value=manifest), patch.object(prepare_cli_core.os, "name", "posix"), patch.object(prepare_cli_core.subprocess, "run") as run:
                with self.assertRaisesRegex(ValueError, "Windows host"):
                    prepare_cli_core.prepare("windows-amd64", output, archive)
            run.assert_not_called()
            self.assertEqual(list(output.iterdir()), [])


class CoreManifestIdentityTests(unittest.TestCase):
    def fixture(self):
        return json.loads((ROOT / "core-lock.json").read_text())

    def read(self, manifest):
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            (directory / "core-lock.json").write_text(json.dumps(manifest))
            return core_manifest.load_manifest(directory)

    def test_real_reviewed_lock_is_valid(self):
        manifest = self.fixture()
        self.assertEqual(self.read(manifest), manifest)

    def test_android_windows_and_quality_overrides_preserve_linux_and_apple_defaults(self):
        core = self.read(self.fixture())["sing_box"]
        self.assertEqual(core["version"], "1.13.12-extended-2.1.2")
        self.assertEqual(core["revision"], "a47bdbe2aefc4da0aa8dd2280fb54c429dd0bfe0")
        for platform in ("linux-amd64",):
            asset = core_manifest.resolve_asset_metadata(core, platform)
            for field in ("version", "tag", "revision"):
                self.assertEqual(asset[field], core[field])
        windows = core_manifest.resolve_asset_metadata(core, "windows-amd64")
        self.assertEqual(windows["version"], "1.14.1-extended-2.7.2")
        self.assertEqual(windows["tag"], "v1.14.1-extended-2.7.2")
        self.assertEqual(windows["revision"], "55faa763f986f4ca8a492d9b2719bc6330d2bef5")
        self.assertTrue(windows["vcs_modified"])
        self.assertIn("+dirty", windows["provenance_note"])
        for platform in ("android-arm64", "android-amd64", "linux-amd64-android-checker"):
            metadata = core_manifest.resolve_asset_metadata(core, platform)
            for field in ("version", "tag", "revision"):
                self.assertEqual(metadata[field], windows[field])
            self.assertTrue(metadata["vcs_modified"])
            self.assertIn("+dirty", metadata["provenance_note"])
        self.assertEqual(core["apple"]["go"], "1.26.8")

    def test_windows_metadata_override_requires_complete_valid_identity(self):
        original = self.fixture()
        for field in ("version", "tag", "revision"):
            manifest = copy.deepcopy(original)
            del manifest["sing_box"]["assets"]["windows-amd64"][field]
            with self.assertRaisesRegex(ValueError, "together"):
                self.read(manifest)
        for field, value in (("version", "latest"), ("version", None), ("tag", "v1.13.12-extended-2.1.2"), ("revision", "main"), ("revision", None)):
            manifest = copy.deepcopy(original)
            manifest["sing_box"]["assets"]["windows-amd64"][field] = value
            with self.assertRaises(ValueError):
                self.read(manifest)

    def test_overrides_on_other_platforms_or_components_and_unknown_fields_rejected(self):
        original = self.fixture()
        windows = original["sing_box"]["assets"]["windows-amd64"]
        for component, platform in (("sing_box", "linux-amd64"), ("tun2socks", "linux-amd64")):
            manifest = copy.deepcopy(original)
            for field in ("version", "tag", "revision"):
                manifest[component]["assets"][platform][field] = windows[field]
            with self.assertRaisesRegex(ValueError, "only for Windows/Android"):
                self.read(manifest)
        manifest = copy.deepcopy(original)
        manifest["sing_box"]["assets"]["windows-arm64"] = copy.deepcopy(windows)
        with self.assertRaisesRegex(ValueError, "platform"):
            self.read(manifest)
        manifest = copy.deepcopy(original)
        manifest["sing_box"]["assets"]["windows-amd64"]["versions"] = {"unexpected": "latest"}
        with self.assertRaisesRegex(ValueError, "fields"):
            self.read(manifest)

    def test_windows_download_must_match_override_tag_and_provenance_is_bounded(self):
        original = self.fixture()
        manifest = copy.deepcopy(original)
        manifest["sing_box"]["assets"]["windows-amd64"]["url"] = original["sing_box"]["assets"]["windows-amd64"]["url"].replace("/download/v1.14.1-extended-2.7.2/", "/download/" + original["sing_box"]["tag"] + "/")
        with self.assertRaisesRegex(ValueError, "pinned release"):
            self.read(manifest)
        for field, value in (("archive_bytes", True), ("installed_bytes", -1), ("installed_bytes", 150 * 1024 * 1024), ("vcs_modified", "false"), ("provenance_note", "")):
            manifest = copy.deepcopy(original)
            manifest["sing_box"]["assets"]["windows-amd64"][field] = value
            with self.assertRaises(ValueError):
                self.read(manifest)

    def test_repository_tag_revision_and_missing_binary_digest_rejected(self):
        original = self.fixture()
        for field, value in (("repository", "https://github.com/other/repo"), ("tag", "v1.14.1-extended-2.7.2"), ("revision", "main")):
            manifest = copy.deepcopy(original)
            manifest["sing_box"][field] = value
            with self.assertRaises(ValueError):
                self.read(manifest)
        manifest = copy.deepcopy(original)
        manifest["sing_box"]["assets"]["windows-amd64"]["installed_sha256"] = None
        with self.assertRaises(ValueError):
            self.read(manifest)

    def test_download_url_cannot_add_query_fragment_or_traverse_release_path(self):
        original = self.fixture()
        url = original["sing_box"]["assets"]["linux-amd64"]["url"]
        for changed in (url + "?redirect=other", url + "#fragment", url.rsplit("/", 1)[0] + "/../other/core.tar.gz"):
            manifest = copy.deepcopy(original)
            manifest["sing_box"]["assets"]["linux-amd64"]["url"] = changed
            with self.assertRaises(ValueError):
                self.read(manifest)


if __name__ == "__main__":
    unittest.main()
