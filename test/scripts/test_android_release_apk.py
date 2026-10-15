"""Release boundaries must cover old updater selection, SDK/ABI and real ELF layout."""
from pathlib import Path
from contextlib import redirect_stdout
from io import StringIO
from unittest.mock import patch
import struct
import sys
import tempfile
import zipfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from validate_android_release_apk import CERTIFICATE, REQUIRED_LIBRARIES, verify_badging, verify_inventory, verify_library_layout, verify_signature_result, verify_unsigned_container
from test_android_core_integrity import executable
import validate_android_release_apk as artifact_gate


class AndroidUniversalArtifactTest(unittest.TestCase):
    def names(self):
        return [f"lib/{abi}/{name}" for abi in ("armeabi-v7a", "arm64-v8a", "x86_64") for name in REQUIRED_LIBRARIES]

    def test_every_abi_requires_both_cores_flutter_and_jni(self):
        names = self.names()
        verify_inventory(names)
        for name in names:
            with self.subTest(missing=name), self.assertRaises(ValueError):
                verify_inventory([n for n in names if n != name])
        for changed in (names + [names[0]], names + ["lib/x86/libsingbox.so"]):
            with self.assertRaises(ValueError):
                verify_inventory(changed)

    def test_manifest_code_abi_sdk_are_all_verified(self):
        text = "package: name='ru.honeyvpn.proxy' versionCode='12129' versionName='1.2.0'\nsdkVersion:'24'\ntargetSdkVersion:'36'\nnative-code: 'armeabi-v7a' 'arm64-v8a' 'x86_64'\n"
        verify_badging(text, "1.2.0", 12129)
        for old, new in (("12129", "4129"), ("ru.honeyvpn.proxy", "ru.foreign.app"), (" 'armeabi-v7a'", ""), ("sdkVersion:'24'", "sdkVersion:'26'"), ("targetSdkVersion:'36'", "targetSdkVersion:'35'")):
            with self.subTest(change=old), self.assertRaises(ValueError):
                verify_badging(text.replace(old, new), "1.2.0", 12129)

    def test_sdk_badging_accepts_actual_aapt2_key_and_rejects_ambiguous_sdk_fields(self):
        text = "package: name='ru.honeyvpn.proxy' versionCode='12129' versionName='1.2.0'\nminSdkVersion:'24'\ntargetSdkVersion:'36'\nnative-code: 'arm64-v8a' 'armeabi-v7a' 'x86_64'\n"
        verify_badging(text, "1.2.0", 12129)
        verify_badging(text.replace("\n", "\r\n"), "1.2.0", 12129)
        for bad in (text.replace("minSdkVersion:'24'", "minSdkVersion:'23'"),
                    text.replace("minSdkVersion:'24'\n", ""),
                    text + "sdkVersion:'24'\n", text + "minSdkVersion:'24'\n",
                    text + "targetSdkVersion:'36'\n", text + "minSdkVersion:'bad'\n",
                    text + "targetSdkVersion:'bad'\n",
                    text.replace("minSdkVersion:'24'", "minSdkVersion:'24' suffix"),
                    text.replace("targetSdkVersion:'36'", "targetSdkVersion:'35'")):
            with self.subTest(bad=bad), self.assertRaisesRegex(ValueError, "SDK range"):
                verify_badging(bad, "1.2.0", 12129)

    def test_external_gate_uses_explicit_reviewed_source_without_rewriting_it(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "frozen-source"
            receipt = root / "receipt.json"
            args = ["gate", "--apk", str(root / "update-universal.apk"), "--source-root", str(source),
                    "--build-tools", str(root / "sdk-tools"), "--strip-tool", str(root / "llvm-strip"),
                    "--java", str(root / "java"), "--receipt", str(receipt), "--unsigned-inspection"]
            with patch.object(sys, "argv", args), patch.object(artifact_gate, "verify", return_value={"Verified": True}) as verify, redirect_stdout(StringIO()):
                artifact_gate.main()
            self.assertEqual(verify.call_args.args[1], source.resolve())
            self.assertEqual(verify.call_args.kwargs, {"unsigned": True})
            self.assertFalse(source.exists())
            self.assertEqual(receipt.read_text(), '{\n  "Verified": true\n}\n')

    def test_32bit_4k_is_valid_while_64bit_4k_and_wrong_architecture_are_rejected(self):
        verify_library_layout(executable(arch="arm", alignment=4096), "armeabi-v7a")
        verify_library_layout(executable(arch="arm64", alignment=16384), "arm64-v8a")
        verify_library_layout(executable(arch="amd64", alignment=16384), "x86_64")
        with self.assertRaisesRegex(ValueError, "page alignment"):
            verify_library_layout(executable(arch="arm64", alignment=4096), "arm64-v8a")
        with self.assertRaisesRegex(ValueError, "ELF class"):
            verify_library_layout(executable(arch="arm"), "arm64-v8a")
        damaged = bytearray(executable(arch="arm"))
        struct.pack_into("<I", damaged, 28, len(damaged))
        with self.assertRaisesRegex(ValueError, "program headers"):
            verify_library_layout(bytes(damaged), "armeabi-v7a")

    def test_unsigned_inspection_cannot_qualify_signed_or_unclassified_artifact(self):
        verify_signature_result(1, "", "Missing META-INF/MANIFEST.MF", True)
        signed = f"Signer #1 certificate SHA-256 digest: {CERTIFICATE}\n"
        verify_signature_result(0, signed, "", False)
        for code, stdout, stderr, unsigned in ((0, signed, "", True), (1, "", "other error", True),
                                               (1, "", "Missing META-INF/MANIFEST.MF", False),
                                               (0, signed.replace(CERTIFICATE, "f" * 64), "", False)):
            with self.assertRaises(ValueError):
                verify_signature_result(code, stdout, stderr, unsigned)

    def test_unsigned_container_refuses_v1_metadata_and_apk_signing_footer(self):
        with tempfile.TemporaryDirectory() as directory:
            apk = Path(directory) / "fixture.apk"
            with zipfile.ZipFile(apk, "w") as archive:
                archive.writestr("AndroidManifest.xml", b"fixture")
            verify_unsigned_container(apk, ["AndroidManifest.xml"])
            with self.assertRaisesRegex(ValueError, "JAR signature"):
                verify_unsigned_container(apk, ["META-INF/CERT.RSA"])
            data = bytearray(apk.read_bytes())
            end = data.rfind(b"PK\x05\x06")
            central = struct.unpack_from("<I", data, end + 16)[0]
            data[central - 16:central] = b"APK Sig Block 42"
            apk.write_bytes(data)
            with self.assertRaisesRegex(ValueError, "APK signing block"):
                verify_unsigned_container(apk, ["AndroidManifest.xml"])

    def test_single_public_universal_asset_is_compatible_with_original_selector(self):
        assets = ["HoneyProxyUtility-v1.2.0-universal.apk"]
        # Exact 1.1.21 selection: prefer a name containing arm64, else first APK.
        selected = next((n for n in assets if "arm64" in n), next(n for n in assets if n.endswith(".apk")))
        self.assertEqual(selected, assets[0])
        workflow = (Path(__file__).resolve().parents[2] / ".github/workflows/build-android.yml").read_text()
        self.assertNotIn("--split-per-abi", workflow)
        self.assertIn("--target-platform android-arm,android-arm64,android-x64", workflow)
        self.assertIn("validate_android_release_apk.py", workflow)
        self.assertIn('APK="build/app/outputs/flutter-apk/HoneyProxyUtility-${TAG}-universal.apk"', workflow)


if __name__ == "__main__":
    unittest.main()
