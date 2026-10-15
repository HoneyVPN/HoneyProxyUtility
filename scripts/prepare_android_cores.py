#!/usr/bin/env python3
"""Install reviewed Android cores only after archive and executable verification."""
from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path, PurePosixPath
import stat
import tarfile
import tempfile
import urllib.parse
import urllib.request
import zipfile

from validate_android_cores import CoreValidationError, MAX_BINARY, ROOT, android_asset_metadata, load_lock, validate_binary

MAX_ARCHIVE = 150 * 1024 * 1024


def safe_name(name: str) -> bool:
    path = PurePosixPath(name)
    return bool(name) and not path.is_absolute() and ".." not in path.parts and "\\" not in name


def archive_binary(path: Path, asset: dict) -> bytes:
    if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_ARCHIVE:
        raise CoreValidationError("Missing or oversized regular core archive")
    if "archive_bytes" in asset and path.stat().st_size != asset["archive_bytes"]:
        raise CoreValidationError("Core archive size does not match core-lock.json")
    if hashlib.sha256(path.read_bytes()).hexdigest() != asset["archive_sha256"]:
        raise CoreValidationError("Core archive SHA-256 does not match core-lock.json")
    member = asset["archive_member"]
    if not safe_name(member):
        raise CoreValidationError("Unsafe locked archive member")
    if zipfile.is_zipfile(path):
        with zipfile.ZipFile(path) as archive:
            matches = []
            for item in archive.infolist():
                if not safe_name(item.filename) or stat.S_ISLNK(item.external_attr >> 16):
                    raise CoreValidationError("Unsafe archive path or symbolic link")
                if item.filename == member:
                    matches.append(item)
            if len(matches) != 1 or matches[0].is_dir() or not 0 < matches[0].file_size <= MAX_BINARY:
                raise CoreValidationError("Expected one bounded regular executable archive member")
            return archive.read(matches[0])
    with tarfile.open(path, "r:gz") as archive:
        matches = []
        for item in archive.getmembers():
            if not safe_name(item.name) or not (item.isfile() or item.isdir()):
                raise CoreValidationError("Unsafe archive path or special file")
            if item.name == member:
                matches.append(item)
        if len(matches) != 1 or not matches[0].isfile() or not 0 < matches[0].size <= MAX_BINARY:
            raise CoreValidationError("Expected one bounded regular executable archive member")
        stream = archive.extractfile(matches[0])
        if stream is None:
            raise CoreValidationError("Missing core archive member")
        return stream.read(MAX_BINARY + 1)


def download_archive(url: str, path: Path) -> None:
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != "https" or parsed.hostname != "github.com" or parsed.query or parsed.fragment:
        raise CoreValidationError("Core download must use the pinned public GitHub HTTPS asset")
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with urllib.request.urlopen(url, timeout=60) as response, tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as target:
            temporary = Path(target.name)
            total = 0
            while chunk := response.read(1024 * 1024):
                total += len(chunk)
                if total > MAX_ARCHIVE:
                    raise CoreValidationError("Downloaded core archive is oversized")
                target.write(chunk)
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def prepare(lock: dict, cache: Path, root: Path, *, download: bool = False) -> list[str]:
    staged = []
    for abi, mapping in lock["android"].items():
        for component, filename in (("sing_box", "libsingbox.so"), ("tun2socks", "libtun2socks.so")):
            asset = android_asset_metadata(lock, abi, component)
            if "build" in asset:
                name = asset["build"]["output_name"]
                if not safe_name(name) or PurePosixPath(name).name != name:
                    raise CoreValidationError("Unsafe built core filename")
                source = cache / name
                # The reviewed tun2socks executables remain tracked inputs.
                # A supplied bad cache entry must still fail, not mask itself
                # behind the existing input. sing-box never uses this fallback.
                if component == "tun2socks" and not source.exists() and not source.is_symlink():
                    source = root / "android/app/src/main/jniLibs" / abi / filename
                if source.is_symlink() or not source.is_file():
                    raise CoreValidationError("Build the locked tun2socks source recipe before installing")
                if source.stat().st_size > MAX_BINARY:
                    raise CoreValidationError("Built tun2socks executable is oversized")
                binary = source.read_bytes()
            else:
                name = PurePosixPath(urllib.parse.urlparse(asset["url"]).path).name
                if not safe_name(name):
                    raise CoreValidationError("Unsafe core archive filename")
                source = cache / name
                if download and not source.exists():
                    download_archive(asset["url"], source)
                binary = archive_binary(source, asset)
            validate_binary(binary, component, asset, asset)
            destination = root / "android/app/src/main/jniLibs" / abi / filename
            if destination.is_symlink() or destination.parent.is_symlink():
                raise CoreValidationError("Core installation destination must not be a symbolic link")
            staged.append((destination, binary, asset["tag"]))
    # Validate all ABI/components before changing any installed executable.
    for destination, binary, version in staged:
        destination.parent.mkdir(parents=True, exist_ok=True)
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as target:
                temporary = Path(target.name)
                target.write(binary)
                target.flush()
                os.fsync(target.fileno())
            # Close the handle before atomic publication on Windows, and avoid
            # Unix-only fchmod on older Windows Python runtimes.
            temporary.chmod(0o755)
            os.replace(temporary, destination)
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)
    return [f"Installed {path.parent.name}/{path.name}: {version}" for path, _, version in staged]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lock", type=Path, default=ROOT / "core-lock.json")
    parser.add_argument("--cache-dir", type=Path, required=True)
    parser.add_argument("--download", action="store_true", help="Download missing pinned release archives")
    args = parser.parse_args()
    try:
        for message in prepare(load_lock(args.lock), args.cache_dir.resolve(), ROOT, download=args.download):
            print(message)
    except (CoreValidationError, KeyError, OSError, ValueError, tarfile.TarError, zipfile.BadZipFile) as exc:
        parser.exit(1, f"Android core preparation failed: {exc}\n")


if __name__ == "__main__":
    main()
