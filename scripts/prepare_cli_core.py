"""Prepare only the exact reviewed CLI binary from core-lock.json."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import stat
import subprocess
import tarfile
import tempfile
import urllib.request
import zipfile

from core_manifest import load_manifest, resolve_asset_metadata


def checked_binary(archive, asset):
    archive_data = archive.read_bytes()
    if "archive_bytes" in asset and len(archive_data) != asset["archive_bytes"]:
        raise ValueError("Core archive size mismatch")
    if hashlib.sha256(archive_data).hexdigest() != asset["archive_sha256"]:
        raise ValueError("Core archive checksum mismatch")
    member = asset["archive_member"]
    if "\\" in member or "\0" in member or re.match(r"^[A-Za-z]:", member) \
            or Path(member).is_absolute() or ".." in Path(member).parts:
        raise ValueError("Unsafe core archive member")
    if archive.suffix == ".zip":
        with zipfile.ZipFile(archive) as container:
            if container.namelist().count(member) != 1:
                raise ValueError("Core archive member must be unambiguous")
            item = container.getinfo(member)
            mode = item.external_attr >> 16
            if item.is_dir() or stat.S_ISLNK(mode) or not 0 < item.file_size < 150 * 1024 * 1024:
                raise ValueError("Core archive member is not a bounded regular binary")
            binary = container.read(item)
    else:
        with tarfile.open(archive, "r:gz") as container:
            if sum(item.name == member for item in container.getmembers()) != 1:
                raise ValueError("Core archive member must be unambiguous")
            item = container.getmember(member)
            if not item.isfile() or not 0 < item.size < 150 * 1024 * 1024:
                raise ValueError("Core archive member is not a bounded regular binary")
            binary = container.extractfile(item).read()
    if "installed_bytes" in asset and len(binary) != asset["installed_bytes"]:
        raise ValueError("Core binary size mismatch")
    if hashlib.sha256(binary).hexdigest() != asset["installed_sha256"]:
        raise ValueError("Core binary checksum mismatch")
    if asset["runtime_assets"]:
        raise ValueError("Additional runtime assets require reviewed packaging")
    return binary


def _require_runtime_host(platform):
    if platform == "windows-amd64" and os.name != "nt":
        raise ValueError("Windows core runtime verification requires a Windows host")


def prepare(platform, output, archive=None):
    core = load_manifest()["sing_box"]
    asset = resolve_asset_metadata(core, platform)
    _require_runtime_host(platform)
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    suffix = ".zip" if platform == "windows-amd64" else ".tar.gz"
    # Download archives stay outside the app output directory: the Windows
    # installer packages that directory recursively.
    cached = Path(archive) if archive else output.parent / "core-download-cache" / ("pinned-core-" + asset["archive_sha256"] + suffix)
    if not archive and not cached.exists():
        cached.parent.mkdir(parents=True, exist_ok=True)
        downloaded = None
        try:
            with tempfile.NamedTemporaryFile(dir=cached.parent, delete=False) as target:
                downloaded = Path(target.name)
                with urllib.request.urlopen(asset["url"], timeout=120) as source:
                    size = 0
                    while block := source.read(1024 * 1024):
                        size += len(block)
                        if size > 150 * 1024 * 1024:
                            raise ValueError("Oversized core archive download")
                        target.write(block)
            if hashlib.sha256(downloaded.read_bytes()).hexdigest() != asset["archive_sha256"]:
                raise ValueError("Core archive checksum mismatch")
            os.replace(downloaded, cached)
        finally:
            if downloaded is not None:
                downloaded.unlink(missing_ok=True)
    data = checked_binary(cached, asset)
    destination = output / ("sing-box.exe" if platform == "windows-amd64" else "sing-box")
    with tempfile.NamedTemporaryFile(dir=output, suffix=".exe" if platform == "windows-amd64" else "", delete=False) as staging:
        staged = Path(staging.name)
        staging.write(data)
    try:
        staged.chmod(0o755)
        result = subprocess.run([str(staged.resolve()), "version"], capture_output=True,
                                text=True, timeout=15, check=True)
        lines = result.stdout.splitlines()
        if not lines or lines[0] != "sing-box version " + asset["version"]:
            raise ValueError("Packaged core version does not match the reviewed manifest")
        if [line for line in lines if line.startswith("Revision:")] != ["Revision: " + asset["revision"]]:
            raise ValueError("Packaged core revision does not match the reviewed manifest")
        os.replace(staged, destination)
    finally:
        staged.unlink(missing_ok=True)
    print("Pinned sing-box " + asset["version"] + " prepared and verified: " + str(destination))
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", required=True,
                        choices=["linux-amd64", "windows-amd64", "linux-amd64-android-checker"])
    parser.add_argument("--output", required=True)
    parser.add_argument("--archive", help="Use an already downloaded archive, still verifying both hashes")
    args = parser.parse_args()
    prepare(args.platform, args.output, args.archive)


if __name__ == "__main__":
    main()
