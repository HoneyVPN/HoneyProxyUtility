#!/usr/bin/env python3
"""Gate the single universal update against its actual manifest and native payload."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import tempfile
import zipfile

from release_metadata import ANDROID_RELEASE_ABIS, validate_android_distribution_version_code
from validate_android_cores import android_asset_metadata, load_lock, validate_binary, validate_installed

ROOT = Path(__file__).resolve().parents[1]
CERTIFICATE = "250ece0f07dc9351d8af53115a900e5c55de2c9574e14970aae8059f605b1e7a"
REQUIRED_LIBRARIES = {"libapp.so", "libflutter.so", "libhoneyvpn_launcher.so", "libsingbox.so", "libtun2socks.so"}


def command_result(arguments: list[str]):
    result = subprocess.run(arguments, capture_output=True, text=True, timeout=120)
    if len(result.stdout) + len(result.stderr) > 1024 * 1024:
        raise ValueError("Android release tool output exceeded the bound")
    return result


def command(arguments: list[str]) -> str:
    result = command_result(arguments)
    if result.returncode:
        raise ValueError("Android release tool rejected the artifact")
    return result.stdout


def verify_signature_result(code: int, stdout: str, stderr: str, unsigned: bool) -> None:
    certs = re.findall(r"(?m)^Signer #(\d+) certificate SHA-256 digest: ([0-9a-fA-F]{64})\s*$", stdout)
    if unsigned:
        if code != 1 or certs or "Missing META-INF/MANIFEST.MF" not in stdout + stderr:
            raise ValueError("Expected an explicitly unsigned APK, not a signed or unclassified artifact")
    elif code != 0 or certs != [("1", CERTIFICATE)]:
        raise ValueError("The universal update must retain the original single signing certificate")


def verify_unsigned_container(apk: Path, names: list[str]) -> None:
    if any(n.upper().startswith("META-INF/") and
           (n.upper() == "META-INF/MANIFEST.MF" or n.upper().endswith((".SF", ".RSA", ".DSA", ".EC"))) for n in names):
        raise ValueError("Unsigned inspection refuses JAR signature metadata")
    # Locate the central directory from the bounded non-ZIP64 EOCD; do not scan
    # arbitrary payload bytes for a signing-block magic string.
    with apk.open("rb") as source:
        size = apk.stat().st_size
        source.seek(max(0, size - 65557))
        tail = source.read(65557)
        end = tail.rfind(b"PK\x05\x06")
        if end < 0 or end + 22 > len(tail):
            raise ValueError("Unsigned APK has no bounded ZIP EOCD")
        comment = struct.unpack_from("<H", tail, end + 20)[0]
        central = struct.unpack_from("<I", tail, end + 16)[0]
        if end + 22 + comment != len(tail) or central == 0xFFFFFFFF or not 24 <= central < size:
            raise ValueError("Unsigned APK ZIP layout is not supported")
        source.seek(central - 24)
        if source.read(24)[8:] == b"APK Sig Block 42":
            raise ValueError("Unsigned inspection refuses an APK signing block")


def verify_badging(text: str, version: str, code: int) -> None:
    package = re.search(r"(?m)^package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'", text)
    native = re.search(r"(?m)^native-code: (.+)$", text)
    if not package or package.groups() != ("ru.honeyvpn.proxy", str(code), version):
        raise ValueError("APK package/versionCode/versionName differs from release metadata")
    if not native or set(re.findall(r"'([^']+)'", native[1])) != set(ANDROID_RELEASE_ABIS):
        raise ValueError("Universal APK manifest must support all three ABIs")
    minimum = re.findall(r"(?m)^(?:minSdkVersion|sdkVersion):([^\r\n]*)\r?$", text)
    target = re.findall(r"(?m)^targetSdkVersion:([^\r\n]*)\r?$", text)
    if minimum != ["'24'"] or target != ["'36'"]:
        raise ValueError("APK SDK range differs from the reviewed Flutter 3.41.7 toolchain")


def verify_library_layout(data: bytes, abi: str) -> None:
    bits, machine = {"armeabi-v7a": (1, 40), "arm64-v8a": (2, 183), "x86_64": (2, 62)}[abi]
    if len(data) < 64 or data[:6] != b"\x7fELF" + bytes([bits, 1]):
        raise ValueError("Packaged library ELF class differs from its ABI directory")
    if struct.unpack_from("<H", data, 18)[0] != machine:
        raise ValueError("Packaged library ELF machine differs from its ABI directory")
    off = struct.unpack_from("<I" if bits == 1 else "<Q", data, 28 if bits == 1 else 32)[0]
    width, count = struct.unpack_from("<HH", data, 42 if bits == 1 else 54)
    if width != (32 if bits == 1 else 56) or not 0 < count <= 64 or off + width * count > len(data):
        raise ValueError("Packaged library has invalid ELF program headers")
    loads = []
    for i in range(count):
        row = struct.unpack_from("<IIIIIIII" if bits == 1 else "<IIQQQQQQ", data, off + i * width)
        if row[0] == 1:
            offset, address, size, memory = (row[1], row[2], row[4], row[5]) if bits == 1 else (row[2], row[3], row[5], row[6])
            alignment = row[7]
            if size > memory or offset + size > len(data) or alignment < (4096 if bits == 1 else 16384) or alignment & (alignment - 1) or offset % alignment != address % alignment:
                raise ValueError("Packaged library does not meet its ABI page alignment")
            loads.append(alignment)
    if not loads:
        raise ValueError("Packaged library has no ELF load segments")


def verify_inventory(names: list[str]) -> None:
    if len(names) != len(set(names)):
        raise ValueError("Duplicate APK entries are not permitted")
    native = {name for name in names if name.startswith("lib/") and not name.endswith("/")}
    abis = {name.split("/")[1] for name in native}
    if abis != set(ANDROID_RELEASE_ABIS):
        raise ValueError("Universal APK native payload must include exactly three supported ABIs")
    for abi in ANDROID_RELEASE_ABIS:
        if not {f"lib/{abi}/{name}" for name in REQUIRED_LIBRARIES} <= native:
            raise ValueError("Universal APK is missing a Flutter, JNI or VPN core library")


def verify(apk: Path, root: Path, tools: Path, strip_tool: Path, java: Path, *, unsigned: bool = False) -> dict:
    match = re.search(r"^version:\s*(\S+)\+(\d+)\s*$", (root / "pubspec.yaml").read_text(), re.M)
    if not match or not apk.name.endswith("-universal.apk") or apk.is_symlink() or not apk.is_file():
        raise ValueError("Expected the single named universal release APK")
    version, build = match.group(1), int(match.group(2))
    code = validate_android_distribution_version_code(build)
    lock = load_lock(root / "core-lock.json")
    validate_installed(root, lock)
    suffix = ".exe" if os.name == "nt" else ""
    verify_badging(command([str(tools / ("aapt2" + suffix)), "dump", "badging", str(apk)]), version, code)
    # Use the same Java/JAR interface on Windows and Unix, never execute .bat via a shell.
    signature = command_result([str(java), "-jar", str(tools / "lib/apksigner.jar"), "verify", "--verbose", "--print-certs", str(apk)])
    verify_signature_result(signature.returncode, signature.stdout, signature.stderr, unsigned)
    command([str(tools / ("zipalign" + suffix)), "-c", "-P", "16", "4", str(apk)])
    payloads = []
    with zipfile.ZipFile(apk) as archive, tempfile.TemporaryDirectory() as scratch:
        verify_inventory(archive.namelist())
        if unsigned:
            verify_unsigned_container(apk, archive.namelist())
        for item in archive.infolist():
            if item.filename.startswith("lib/") and not item.is_dir():
                if not 0 < item.file_size <= 200 * 1024 * 1024:
                    raise ValueError("Packaged native library exceeds the bound")
                verify_library_layout(archive.read(item), item.filename.split("/")[1])
        for abi in ANDROID_RELEASE_ABIS:
            for component, name in (("sing_box", "libsingbox.so"), ("tun2socks", "libtun2socks.so")):
                asset = android_asset_metadata(lock, abi, component)
                source = (root / "android/app/src/main/jniLibs" / abi / name).read_bytes()
                validate_binary(source, component, asset, asset)
                packed = archive.read(f"lib/{abi}/{name}")
                if packed != source:
                    replay = Path(scratch) / (abi + "-" + name)
                    replay.write_bytes(source)
                    command([str(strip_tool), "--strip-unneeded", str(replay)])
                    if packed != replay.read_bytes():
                        raise ValueError("Packaged VPN core differs from its locked source/NDK strip replay")
                payloads.append({"Abi": abi, "Library": name, "PackagedSHA256": hashlib.sha256(packed).hexdigest(), "SourceSHA256": asset["installed_sha256"]})
    return {"Status": "ANDROID_UNIVERSAL_UNSIGNED_PAYLOAD_INSPECTED_NOT_RELEASE_VERIFIED" if unsigned else "ANDROID_UNIVERSAL_RELEASE_APK_VERIFIED",
            "ReleaseSignatureVerified": not unsigned, "SigningPerformed": False, "VersionName": version, "VersionCode": code,
            "Abis": list(ANDROID_RELEASE_ABIS), "ApkSHA256": hashlib.sha256(apk.read_bytes()).hexdigest(),
            "ApkBytes": apk.stat().st_size, "CertificateSHA256": None if unsigned else CERTIFICATE, "ZipAlign16Verified": True,
            "AllNativeLibraryAbiPageAlignmentVerified": True, "CoreSourceOrStripReplayVerified": payloads}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apk", required=True, type=Path)
    parser.add_argument("--source-root", type=Path, default=ROOT, help="Reviewed app source and locked native core directory")
    parser.add_argument("--build-tools", required=True, type=Path)
    parser.add_argument("--strip-tool", required=True, type=Path)
    parser.add_argument("--receipt", required=True, type=Path)
    parser.add_argument("--java", required=True, type=Path)
    parser.add_argument("--unsigned-inspection", action="store_true", help="Pre-sign payload QA only; never qualifies a release")
    args = parser.parse_args()
    result = verify(args.apk.resolve(), args.source_root.resolve(), args.build_tools.resolve(), args.strip_tool.resolve(), args.java.resolve(), unsigned=args.unsigned_inspection)
    with args.receipt.open("x") as target:
        json.dump(result, target, indent=2)
        target.write("\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
