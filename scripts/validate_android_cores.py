#!/usr/bin/env python3
"""Verify packaged executable cores against the reviewed lock without running VPN."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import struct

from core_manifest import resolve_asset_metadata, validate_manifest

ROOT = Path(__file__).resolve().parents[1]
MAX_BINARY = 200 * 1024 * 1024
GO_MAGIC = b"\xff Go buildinf:"
ANDROID_LIBRARIES = {"liblog.so", "libdl.so", "libm.so", "libc.so"}


class CoreValidationError(ValueError):
    pass


def checked_slice(data: bytes, offset: int, size: int) -> bytes:
    if offset < 0 or size < 0 or offset + size > len(data):
        raise CoreValidationError("Truncated executable metadata")
    return data[offset:offset + size]


def inline_string(data: bytes, offset: int) -> tuple[bytes, int]:
    length = 0
    for shift in range(0, 70, 7):
        byte = checked_slice(data, offset, 1)[0]
        offset += 1
        length |= (byte & 127) << shift
        if byte < 128:
            if length > 1024 * 1024:
                raise CoreValidationError("Oversized Go build metadata")
            return checked_slice(data, offset, length), offset + length
    raise CoreValidationError("Invalid Go build metadata length")


def inspect_executable(data: bytes) -> dict:
    if not 64 <= len(data) <= MAX_BINARY:
        raise CoreValidationError("Invalid executable size")
    if data[:4] != b"\x7fELF" or data[4] not in (1, 2) or data[5] != 1:
        raise CoreValidationError("Expected a little-endian 32/64-bit ELF executable")
    bits = 32 if data[4] == 1 else 64
    kind, machine = struct.unpack_from("<HH", data, 16)
    if kind not in (2, 3) or machine not in ({40} if bits == 32 else {62, 183}):
        raise CoreValidationError("Unsupported ELF executable architecture/type")
    phoff = struct.unpack_from("<I" if bits == 32 else "<Q", data, 28 if bits == 32 else 32)[0]
    phsize, count = struct.unpack_from("<HH", data, 42 if bits == 32 else 54)
    if phsize != (32 if bits == 32 else 56) or not 0 < count <= 64:
        raise CoreValidationError("Invalid ELF program header layout")
    checked_slice(data, phoff, phsize * count)
    segments = []
    interpreter = None
    for index in range(count):
        if bits == 32:
            kind32, offset32, address32, physical32, size32, memory32, flags32, alignment32 = struct.unpack_from("<IIIIIIII", data, phoff + index * phsize)
            entry = (kind32, flags32, offset32, address32, physical32, size32, memory32, alignment32)
        else:
            entry = struct.unpack_from("<IIQQQQQQ", data, phoff + index * phsize)
        segment_type, _, offset, address, _, size, memory_size, alignment = entry
        checked_slice(data, offset, size)
        if memory_size < size:
            raise CoreValidationError("Invalid ELF segment size")
        if segment_type == 1:
            if alignment < 4096 or alignment & (alignment - 1) or offset % alignment != address % alignment:
                raise CoreValidationError("Invalid ELF load segment alignment")
        if segment_type == 3:
            raw = checked_slice(data, offset, size)
            if interpreter is not None or not raw.endswith(b"\0") or len(raw) > 128:
                raise CoreValidationError("Invalid ELF interpreter")
            interpreter = raw[:-1].decode("ascii")
        segments.append(entry)
    loads = [segment for segment in segments if segment[0] == 1]
    if not loads:
        raise CoreValidationError("Executable has no load segments")
    needed = []
    dynamics = [segment for segment in segments if segment[0] == 2]
    if len(dynamics) > 1:
        raise CoreValidationError("Multiple ELF dynamic tables")
    if dynamics:
        dynamic = dynamics[0]
        dynamic_size = 8 if bits == 32 else 16
        if dynamic[5] % dynamic_size:
            raise CoreValidationError("Invalid ELF dynamic table")
        entries = [struct.unpack_from("<iI" if bits == 32 else "<qQ", data, dynamic[2] + index)
                   for index in range(0, dynamic[5], dynamic_size)]
        table = next((value for key, value in entries if key == 5), None)
        length = next((value for key, value in entries if key == 10), None)
        requests = [value for key, value in entries if key == 1]
        if requests:
            load = next((segment for segment in loads if table is not None and segment[3] <= table < segment[3] + segment[5]), None)
            if load is None or length is None:
                raise CoreValidationError("Missing ELF dependency string table")
            strings = checked_slice(data, load[2] + table - load[3], length)
            for offset in requests:
                end = strings.find(b"\0", offset)
                if offset >= len(strings) or end < 0:
                    raise CoreValidationError("Invalid ELF dependency name")
                needed.append(strings[offset:end].decode("ascii"))
    offset = data.find(GO_MAGIC)
    if offset < 0 or offset % 16:
        raise CoreValidationError("Missing Go build information")
    header = checked_slice(data, offset, 32)
    if header[14] != bits // 8 or not header[15] & 2:
        raise CoreValidationError("Unsupported Go build information format")
    raw_go_version, next_offset = inline_string(data, offset + 32)
    framed_modules, _ = inline_string(data, next_offset)
    if len(framed_modules) < 32:
        raise CoreValidationError("Missing Go module information")
    try:
        go_version = raw_go_version.decode("utf-8")
        modules = framed_modules[16:-16].decode("utf-8")
    except UnicodeDecodeError as exc:
        raise CoreValidationError("Invalid Go build metadata encoding") from exc
    build = {}
    module = None
    for line in modules.splitlines():
        parts = line.split("\t")
        if parts[0] == "mod" and len(parts) >= 3:
            module = parts[1:3]
        elif parts[0] == "build" and len(parts) == 2 and "=" in parts[1]:
            key, value = parts[1].split("=", 1)
            if key in build:
                raise CoreValidationError("Duplicate Go build setting")
            build[key] = value
    if module is None:
        raise CoreValidationError("Missing main Go module")
    return {"bits": bits, "kind": kind, "machine": machine, "interpreter": interpreter,
            "load_alignments": [segment[7] for segment in loads], "needed": needed,
            "go_version": go_version, "module": module, "build": build}


def validate_binary(data: bytes, component: str, pin: dict, asset: dict) -> dict:
    if "installed_bytes" in asset and len(data) != asset["installed_bytes"]:
        raise CoreValidationError("Installed executable size does not match core-lock.json")
    if hashlib.sha256(data).hexdigest() != asset["installed_sha256"]:
        raise CoreValidationError("Installed executable SHA-256 does not match core-lock.json")
    info = inspect_executable(data)
    expected_arch = asset["expected_goarch"]
    if info["machine"] != {"arm": 40, "arm64": 183, "amd64": 62}[expected_arch]:
        raise CoreValidationError("ELF architecture does not match the selected Android ABI")
    for key, expected in (("GOOS", asset["expected_goos"]), ("GOARCH", expected_arch), ("vcs.revision", pin["revision"])):
        if info["build"].get(key) != expected:
            raise CoreValidationError(f"Go build setting {key} does not match the reviewed core")
    if expected_arch == "arm" and info["build"].get("GOARM") != "7":
        raise CoreValidationError("Android ARM32 requires the reviewed GOARM=7 target")
    if "go_version" in asset and info["go_version"] != asset["go_version"]:
        raise CoreValidationError("Go compiler version does not match core provenance")
    if "vcs_modified" in asset and info["build"].get("vcs.modified") != str(asset["vcs_modified"]).lower():
        raise CoreValidationError("Go source-tree provenance does not match the reviewed core")
    module = "github.com/sagernet/sing-box" if component == "sing_box" else "github.com/xjasonlyu/tun2socks/v2"
    versions = {pin["tag"], pin["tag"] + "+dirty"}
    if "vcs_modified" in asset:
        versions = {pin["tag"] + ("+dirty" if asset["vcs_modified"] else "")}
    if info["module"][0] != module or info["module"][1] not in versions:
        raise CoreValidationError("Go module version does not match the reviewed core")
    if min(info["load_alignments"]) < asset.get("minimum_load_alignment", 16384):
        raise CoreValidationError("Executable does not meet the locked Android page alignment")
    if component == "sing_box":
        loader = "/system/bin/linker" if expected_arch == "arm" else "/system/bin/linker64"
        if info["kind"] != 3 or info["interpreter"] != loader or set(info["needed"]) - ANDROID_LIBRARIES:
            raise CoreValidationError("Android sing-box requires an unexpected runtime library/loader")
        required_tags = {"with_quic", "with_wireguard", "with_utls", "with_clash_api"}
        if not required_tags <= set(info["build"].get("-tags", "").split(",")):
            raise CoreValidationError("Android sing-box is missing required protocol/status features")
    elif info["kind"] != 2 or info["interpreter"] is not None or info["needed"] or info["build"].get("CGO_ENABLED") != "0":
        raise CoreValidationError("tun2socks must be a standalone static executable")
    if asset.get("runtime_assets", []):
        raise CoreValidationError("Additional runtime assets need explicit packaging support")
    return info


def android_asset_metadata(lock: dict, abi: str, component: str) -> dict:
    target, arch = {"armeabi-v7a": ("armv7", "arm"), "arm64-v8a": ("arm64", "arm64"),
                    "x86_64": ("amd64", "amd64")}[abi]
    platform = ("android-" if component == "sing_box" else "linux-") + target
    if lock["android"][abi][component + "_asset"] != platform:
        raise CoreValidationError("Core asset does not match its Android ABI mapping")
    try:
        metadata = resolve_asset_metadata(lock[component], platform)
    except ValueError as exc:
        raise CoreValidationError(str(exc)) from exc
    expected_os = "android" if component == "sing_box" else "linux"
    if metadata.get("expected_goarch") != arch or metadata.get("expected_goos") != expected_os:
        raise CoreValidationError("Core target does not match its Android ABI mapping")
    return metadata


def load_lock(path: Path) -> dict:
    try:
        lock = validate_manifest(json.loads(path.read_text()))
    except ValueError as exc:
        raise CoreValidationError(str(exc)) from exc
    if set(lock["android"]) != {"armeabi-v7a", "arm64-v8a", "x86_64"}:
        raise CoreValidationError("Unsupported core lock Android ABI set")
    for abi in lock["android"]:
        for component in ("sing_box", "tun2socks"):
            android_asset_metadata(lock, abi, component)
    return lock


def validate_installed(root: Path, lock: dict) -> list[str]:
    checked = []
    for abi, mapping in lock["android"].items():
        for component, filename in (("sing_box", "libsingbox.so"), ("tun2socks", "libtun2socks.so")):
            path = root / "android/app/src/main/jniLibs" / abi / filename
            if path.is_symlink() or not path.is_file():
                raise CoreValidationError(f"Missing regular native core: {abi}/{filename}")
            if path.stat().st_size > MAX_BINARY:
                raise CoreValidationError(f"Oversized native core: {abi}/{filename}")
            asset = android_asset_metadata(lock, abi, component)
            info = validate_binary(path.read_bytes(), component, asset, asset)
            checked.append(f"{abi}/{filename}: {asset['tag']}, {info['go_version']}, SHA-256/ELF/ABI/provenance verified")
    return checked


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lock", type=Path, default=ROOT / "core-lock.json")
    args = parser.parse_args()
    try:
        for message in validate_installed(ROOT, load_lock(args.lock)):
            print(message)
    except (CoreValidationError, KeyError, OSError, ValueError) as exc:
        parser.exit(1, f"Android core verification failed: {exc}\n")


if __name__ == "__main__":
    main()
