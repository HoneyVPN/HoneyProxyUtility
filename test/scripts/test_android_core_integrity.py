"""Corrupt packaging/provenance fixtures must fail before installed cores change."""
import hashlib
import json
from pathlib import Path
import stat
import struct
import sys
import tarfile
import tempfile
import unittest
import warnings
import zipfile
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from prepare_android_cores import archive_binary, prepare
from core_manifest import SING_BOX_REPOSITORY, TUN2SOCKS_REPOSITORY
from validate_android_cores import CoreValidationError, inspect_executable, load_lock, validate_binary, validate_installed
import prepare_android_cores


REVISION = "a" * 40


def varint(value):
    result = bytearray()
    while value >= 128:
        result.append((value & 127) | 128)
        value >>= 7
    result.append(value)
    return bytes(result)


def executable(component="tun2socks", arch="arm64", *, revision=REVISION, alignment=16384,
               version="v2.7.0", vcs_modified=None):
    data = bytearray(8192)
    arm32 = arch == "arm"
    data[:6] = b"\x7fELF" + bytes([1 if arm32 else 2, 1])
    struct.pack_into("<HH", data, 16, 2 if component == "tun2socks" else 3,
                     {"arm": 40, "arm64": 183, "amd64": 62}[arch])
    if arm32:
        struct.pack_into("<I", data, 28, 64)
        struct.pack_into("<HH", data, 42, 32, 1 if component == "tun2socks" else 2)
        struct.pack_into("<IIIIIIII", data, 64, 1, 0, 0, 0, len(data), len(data), 5, alignment)
    else:
        struct.pack_into("<Q", data, 32, 64)
        struct.pack_into("<HH", data, 54, 56, 1 if component == "tun2socks" else 2)
        struct.pack_into("<IIQQQQQQ", data, 64, 1, 5, 0, 0, 0, len(data), len(data), alignment)
    if component == "sing_box":
        interpreter = b"/system/bin/linker\0" if arm32 else b"/system/bin/linker64\0"
        if arm32:
            struct.pack_into("<IIIIIIII", data, 96, 3, 192, 192, 192, len(interpreter), len(interpreter), 4, 1)
        else:
            struct.pack_into("<IIQQQQQQ", data, 120, 3, 4, 192, 192, 192, len(interpreter), len(interpreter), 1)
        data[192:192 + len(interpreter)] = interpreter
    module = "github.com/xjasonlyu/tun2socks/v2" if component == "tun2socks" else "github.com/sagernet/sing-box"
    provenance = "" if vcs_modified is None else f"build\tvcs.modified={str(vcs_modified).lower()}\n"
    if arm32:
        provenance += "build\tGOARM=7\n"
    text = (f"path\t{module}\nmod\t{module}\t{version}\t\n"
            f"build\tGOARCH={arch}\nbuild\tGOOS={'linux' if component == 'tun2socks' else 'android'}\n"
            f"build\tCGO_ENABLED=0\nbuild\tvcs.revision={revision}\n"
            "build\t-tags=with_quic,with_wireguard,with_utls,with_clash_api\n" + provenance).encode()
    framed = b"\xff" * 16 + text + b"\xff" * 16
    header = b"\xff Go buildinf:" + bytes([4 if arm32 else 8, 2]) + b"\0" * 16
    version = b"go1.26.8"
    info = header + varint(len(version)) + version + varint(len(framed)) + framed
    data[256:256 + len(info)] = info
    return bytes(data)


def asset(data, arch="arm64", component="tun2socks"):
    return {"installed_sha256": hashlib.sha256(data).hexdigest(), "expected_goarch": arch,
            "expected_goos": "linux" if component == "tun2socks" else "android", "go_version": "go1.26.8",
            "runtime_assets": [], "minimum_load_alignment": 4096 if arch == "arm" else 16384}


def pin(component="tun2socks"):
    return {"repository": SING_BOX_REPOSITORY if component == "sing_box" else TUN2SOCKS_REPOSITORY,
            "version": "2.7.0", "tag": "v2.7.0", "revision": REVISION}


class AndroidCoreIntegrityTests(unittest.TestCase):
    def test_valid_static_core_and_binary_framing(self):
        data = executable()
        info = validate_binary(data, "tun2socks", pin(), asset(data))
        self.assertEqual(info["module"], ["github.com/xjasonlyu/tun2socks/v2", "v2.7.0"])
        self.assertEqual(info["needed"], [])

    def test_armv7_requires_elf32_matching_goarm_and_android_loader(self):
        for component in ("sing_box", "tun2socks"):
            data = executable(component, "arm", alignment=4096)
            info = validate_binary(data, component, pin(component), asset(data, "arm", component))
            self.assertEqual((info["bits"], info["machine"]), (32, 40))
            self.assertEqual(info["build"]["GOARM"], "7")
            if component == "sing_box":
                self.assertEqual(info["interpreter"], "/system/bin/linker")
            wrong_arm = data.replace(b"GOARM=7", b"GOARM=6")
            with self.assertRaisesRegex(CoreValidationError, "GOARM=7"):
                validate_binary(wrong_arm, component, pin(component), asset(wrong_arm, "arm", component))
            with self.assertRaisesRegex(CoreValidationError, "architecture"):
                validate_binary(data, component, pin(component), asset(data, "arm64", component))

    def test_elf_class_pointer_size_and_truncated_arm32_headers_rejected(self):
        data = bytearray(executable(arch="arm"))
        data[256 + 14] = 8
        with self.assertRaisesRegex(CoreValidationError, "Go build information format"):
            inspect_executable(bytes(data))
        with self.assertRaises(CoreValidationError):
            inspect_executable(executable(arch="arm")[:80])
        data = bytearray(executable(arch="arm"))
        struct.pack_into("<H", data, 18, 183)
        with self.assertRaisesRegex(CoreValidationError, "architecture"):
            inspect_executable(bytes(data))

    def test_modified_executable_rejected(self):
        original = executable()
        damaged = original[:-1] + b"1"
        with self.assertRaisesRegex(CoreValidationError, "SHA-256"):
            validate_binary(damaged, "tun2socks", pin(), asset(original))

    def test_reviewed_size_and_explicit_dirty_provenance_are_enforced(self):
        data = executable("sing_box", version="v1.14.1-extended-2.7.2+dirty", vcs_modified=True)
        record = dict(asset(data, component="sing_box"), installed_bytes=len(data), vcs_modified=True)
        identity = dict(pin("sing_box"), tag="v1.14.1-extended-2.7.2")
        validate_binary(data, "sing_box", identity, record)
        with self.assertRaisesRegex(CoreValidationError, "size"):
            validate_binary(data, "sing_box", identity, dict(record, installed_bytes=len(data) + 1))
        with self.assertRaisesRegex(CoreValidationError, "source-tree provenance"):
            validate_binary(data, "sing_box", identity, dict(record, vcs_modified=False))
        clean_module = executable("sing_box", version=identity["tag"], vcs_modified=True)
        with self.assertRaisesRegex(CoreValidationError, "module version"):
            validate_binary(clean_module, "sing_box", identity,
                            dict(asset(clean_module, component="sing_box"), vcs_modified=True))

    def test_other_abi_and_other_source_revision_rejected(self):
        data = executable()
        with self.assertRaisesRegex(CoreValidationError, "architecture"):
            validate_binary(data, "tun2socks", pin(), asset(data, "amd64"))
        data = executable(revision="b" * 40)
        with self.assertRaisesRegex(CoreValidationError, "vcs.revision"):
            validate_binary(data, "tun2socks", pin(), asset(data))

    def test_4k_only_executable_rejected(self):
        data = executable(alignment=4096)
        with self.assertRaisesRegex(CoreValidationError, "page alignment"):
            validate_binary(data, "tun2socks", pin(), asset(data))

    def test_truncated_elf_and_forged_go_lengths_rejected(self):
        with self.assertRaises(CoreValidationError):
            inspect_executable(executable()[:100])
        data = bytearray(executable())
        data[288:298] = b"\xff" * 10
        with self.assertRaisesRegex(CoreValidationError, "metadata length"):
            inspect_executable(bytes(data))

    def test_android_loader_cannot_be_host_linux_loader(self):
        data = bytearray(executable("sing_box"))
        replacement = b"/lib64/ld-linux.so\0"
        data[192:212] = replacement.ljust(20, b"\0")
        with self.assertRaisesRegex(CoreValidationError, "runtime library/loader"):
            validate_binary(bytes(data), "sing_box", pin(), asset(bytes(data), component="sing_box"))

    def write_zip(self, directory, entries):
        path = directory / "core.zip"
        with zipfile.ZipFile(path, "w") as archive:
            for name, contents, mode in entries:
                item = zipfile.ZipInfo(name)
                item.external_attr = mode << 16
                with warnings.catch_warnings():
                    warnings.simplefilter("ignore", UserWarning)
                    archive.writestr(item, contents)
        return path, {"archive_sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "archive_member": "core"}

    def test_safe_member_is_read_without_extracting_other_files(self):
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            path, lock = self.write_zip(directory, [("core", b"payload", stat.S_IFREG), ("LICENSE", b"text", stat.S_IFREG)])
            self.assertEqual(archive_binary(path, lock), b"payload")
            self.assertFalse((directory / "LICENSE").exists())
            with self.assertRaisesRegex(CoreValidationError, "archive size"):
                archive_binary(path, dict(lock, archive_bytes=path.stat().st_size + 1))

    def test_traversal_links_and_duplicate_executables_rejected(self):
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            for entries in [[("core", b"ok", stat.S_IFREG), ("../escape", b"bad", stat.S_IFREG)],
                            [("core", b"target", stat.S_IFLNK)],
                            [("core", b"first", stat.S_IFREG), ("core", b"second", stat.S_IFREG)]]:
                path, lock = self.write_zip(directory, entries)
                with self.assertRaises(CoreValidationError):
                    archive_binary(path, lock)
            self.assertFalse((directory.parent / "escape").exists())

    def test_tar_link_and_wrong_archive_digest_rejected(self):
        with tempfile.TemporaryDirectory() as name:
            path = Path(name) / "core.tar.gz"
            with tarfile.open(path, "w:gz") as archive:
                item = tarfile.TarInfo("core")
                item.type = tarfile.SYMTYPE
                item.linkname = "../escape"
                archive.addfile(item)
            lock = {"archive_member": "core", "archive_sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
            with self.assertRaisesRegex(CoreValidationError, "special file"):
                archive_binary(path, lock)
            lock["archive_sha256"] = "0" * 64
            with self.assertRaisesRegex(CoreValidationError, "SHA-256"):
                archive_binary(path, lock)

    def preparation_fixture(self, root, *, android_override=False):
        cache = root / "cache"
        cache.mkdir()
        lock = {"schema_version": 1, "android": {}, "sing_box": dict(pin("sing_box"), assets={}),
                "tun2socks": dict(pin(), assets={})}
        destinations = []
        for abi, arch in (("armeabi-v7a", "arm"), ("arm64-v8a", "arm64"), ("x86_64", "amd64")):
            lock["android"][abi] = {}
            for component, filename in (("sing_box", "libsingbox.so"), ("tun2socks", "libtun2socks.so")):
                key = ("android-" if component == "sing_box" else "linux-") + ("armv7" if arch == "arm" else arch)
                override = component == "sing_box" and android_override
                version = "1.14.1-extended-2.7.2" if override else "2.7.0"
                revision = "b" * 40 if override else REVISION
                data = executable(component, arch, revision=revision,
                                  version="v" + version + ("+dirty" if override else ""),
                                  vcs_modified=True if override else None)
                record = asset(data, arch, component)
                if override:
                    record.update(version=version, tag="v" + version, revision=revision,
                                  vcs_modified=True, installed_bytes=len(data))
                archive_name = key + ".zip"
                path, archive_lock = self.write_zip(cache, [("core", data, stat.S_IFREG)])
                archive_bytes = path.stat().st_size
                path.rename(cache / archive_name)
                record.update(archive_lock, archive_bytes=archive_bytes,
                              url=lock[component]["repository"] + "/releases/download/v" + version + "/" + archive_name)
                lock[component]["assets"][key] = record
                lock["android"][abi][component + "_asset"] = key
                destination = root / "android/app/src/main/jniLibs" / abi / filename
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(b"original")
                destinations.append(destination)
        return lock, cache, destinations

    def test_last_corrupt_abi_does_not_replace_any_installed_core(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            lock, cache, destinations = self.preparation_fixture(root)
            lock["tun2socks"]["assets"]["linux-amd64"]["installed_sha256"] = "0" * 64
            with self.assertRaises(CoreValidationError):
                prepare(lock, cache, root)
            self.assertTrue(all(path.read_bytes() == b"original" for path in destinations))

    def test_android_override_is_used_for_archive_preparation_and_installed_validation(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            lock, cache, destinations = self.preparation_fixture(root, android_override=True)
            path = root / "custom-lock.json"
            path.write_text(json.dumps(lock))
            loaded = load_lock(path)
            messages = prepare(loaded, cache, root)
            self.assertEqual(len(messages), 6)
            self.assertTrue(all(path.read_bytes() != b"original" for path in destinations))
            checked = validate_installed(root, loaded)
            self.assertEqual(sum("v1.14.1-extended-2.7.2" in line for line in checked), 3)
            self.assertEqual(sum("v2.7.0" in line for line in checked), 3)
            self.assertEqual(lock["sing_box"]["tag"], "v2.7.0", "The global/Apple identity is unchanged.")

    def test_wrong_override_revision_or_partial_identity_cannot_replace_any_core(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            lock, cache, destinations = self.preparation_fixture(root, android_override=True)
            record = lock["sing_box"]["assets"]["android-amd64"]
            correct_revision = record["revision"]
            record["revision"] = "c" * 40
            with self.assertRaisesRegex(CoreValidationError, "vcs.revision"):
                prepare(lock, cache, root)
            self.assertTrue(all(path.read_bytes() == b"original" for path in destinations))
            record["revision"] = correct_revision
            del record["tag"]
            with self.assertRaisesRegex(CoreValidationError, "together"):
                prepare(lock, cache, root)
            self.assertTrue(all(path.read_bytes() == b"original" for path in destinations))

    def test_verified_inputs_are_closed_before_windows_compatible_publication(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            lock, cache, _ = self.preparation_fixture(root, android_override=True)
            targets = []
            original_temporary = tempfile.NamedTemporaryFile
            original_replace = prepare_android_cores.os.replace

            def temporary(**kwargs):
                target = original_temporary(**kwargs)
                targets.append(target)
                return target

            def publish(source, destination):
                self.assertTrue(targets[-1].closed, "Windows must not rename an open temporary input.")
                original_replace(source, destination)

            with patch.object(prepare_android_cores.tempfile, "NamedTemporaryFile", side_effect=temporary), \
                    patch.object(prepare_android_cores.os, "replace", side_effect=publish), \
                    patch.object(prepare_android_cores.os, "fchmod", side_effect=AssertionError("Not portable"), create=True):
                prepare(lock, cache, root)
            self.assertEqual(len(targets), 6)

    def test_missing_built_tun2socks_cache_can_use_only_verified_tracked_inputs(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            lock, cache, destinations = self.preparation_fixture(root, android_override=True)
            built = []
            for abi in lock["android"]:
                key = lock["android"][abi]["tun2socks_asset"]
                record = lock["tun2socks"]["assets"][key]
                archive = cache / (key + ".zip")
                existing = root / "android/app/src/main/jniLibs" / abi / "libtun2socks.so"
                existing.write_bytes(archive_binary(archive, record))
                for field in ("url", "archive_member", "archive_sha256", "archive_bytes"):
                    del record[field]
                record["build"] = {"output_name": "tun2socks-" + key}
                built.append(cache / record["build"]["output_name"])
            previous = [path.read_bytes() for path in destinations]
            built[-1].write_bytes(b"supplied invalid built input")
            with self.assertRaisesRegex(CoreValidationError, "SHA-256"):
                prepare(lock, cache, root)
            self.assertEqual([path.read_bytes() for path in destinations], previous)
            built[-1].unlink()
            prepare(lock, cache, root)
            self.assertEqual(len(validate_installed(root, lock)), 6)
            self.assertTrue(all(not path.exists() for path in built))

    def test_swapped_android_asset_mapping_is_rejected_before_publication(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            lock, cache, destinations = self.preparation_fixture(root, android_override=True)
            lock["android"]["arm64-v8a"]["sing_box_asset"] = "android-amd64"
            with self.assertRaisesRegex(CoreValidationError, "ABI mapping"):
                prepare(lock, cache, root)
            self.assertTrue(all(path.read_bytes() == b"original" for path in destinations))
            path = root / "custom-lock.json"
            path.write_text(json.dumps(lock))
            with self.assertRaisesRegex(CoreValidationError, "ABI mapping"):
                load_lock(path)


if __name__ == "__main__":
    unittest.main()
