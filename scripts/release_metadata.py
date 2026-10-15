"""Fail a release before signing/deploying mismatched or incomplete artifacts."""
import argparse
from collections.abc import Mapping
import os
from pathlib import Path
import re
import subprocess
from typing import Optional

from core_manifest import load_manifest
from validate_android_cores import validate_installed

# Flutter 3.41.7's split-per-ABI Gradle plugin adds ABI_VERSION * 1000 to
# the pubspec/--build-number base. x86_64 is ABI_VERSION 4; 3 is reserved.
ANDROID_SPLIT_VERSION_CODE_OFFSETS = {"arm64-v8a": 2000, "x86_64": 4000}
# Public 1.1.21 used base 121 (cf36ea6) and the same split build/Flutter SDK.
# arm64 2121 was verified from the APK; x86_64 4121 is inferred from that
# source/build configuration, not independently verified old APK badging.
LAST_PUBLISHED_ANDROID_VERSION_CODES = {"arm64-v8a": 2121, "x86_64": 4121}
MAX_ANDROID_VERSION_CODE = 2_100_000_000
MAX_ANDROID_SPLIT_BUILD_NUMBER = (
    MAX_ANDROID_VERSION_CODE - max(ANDROID_SPLIT_VERSION_CODE_OFFSETS.values())
)


def android_split_version_codes(build_number: int) -> dict[str, int]:
    """Historical split codes for migration checks, before APK badging."""
    if type(build_number) is not int or build_number <= 0:
        raise ValueError("Android base build number must be a positive integer")
    if build_number > MAX_ANDROID_SPLIT_BUILD_NUMBER:
        raise ValueError(
            "Android base build number exceeds the split APK versionCode limit "
            f"({MAX_ANDROID_SPLIT_BUILD_NUMBER})"
        )
    return {
        abi: build_number + offset
        for abi, offset in ANDROID_SPLIT_VERSION_CODE_OFFSETS.items()
    }


def validate_android_version_code(
    build_number: int,
    *,
    previous_codes: Optional[Mapping[str, int]] = None,
) -> dict[str, int]:
    """Validate a base build against each ABI's previous actual/expected code.

    Callers validating an update from private candidates can supply their
    verified per-ABI baseline instead of the older public release baseline.
    These split offsets must not be reused for universal APKs or app bundles.
    """
    codes = android_split_version_codes(build_number)
    baseline = (
        LAST_PUBLISHED_ANDROID_VERSION_CODES
        if previous_codes is None else previous_codes
    )
    if not isinstance(baseline, Mapping) or set(baseline) != set(codes):
        raise ValueError(
            "Previous split APK baseline must contain exactly arm64-v8a and x86_64"
        )
    for abi, code in codes.items():
        previous = baseline[abi]
        if (type(previous) is not int or previous <= 0 or
                previous > MAX_ANDROID_VERSION_CODE):
            raise ValueError(
                f"Previous versionCode for {abi} must be a positive integer within the limit"
            )
        if code <= previous:
            raise ValueError(
                f"Android {abi} APK versionCode {code} (base build {build_number}) "
                f"must exceed previous versionCode {previous}"
            )
    return codes


# New universal APK and Play AAB artifacts share one code. Unlike Flutter's
# historical ABI offsets this remains monotonic when the distribution changes.
ANDROID_DISTRIBUTION_CODE_OFFSET = 10_000
MIN_ANDROID_DISTRIBUTION_BUILD = 2129
ANDROID_RELEASE_ABIS = ("armeabi-v7a", "arm64-v8a", "x86_64")
# Highest known old-format private split code (2129 + x86_64's 4000).
LAST_LEGACY_ANDROID_CODE = 6129


def android_distribution_version_code(build_number: int) -> int:
    if type(build_number) is not int or build_number <= 0:
        raise ValueError("Android base build number must be a positive integer")
    code = ANDROID_DISTRIBUTION_CODE_OFFSET + build_number
    if code > MAX_ANDROID_VERSION_CODE:
        raise ValueError("Android distribution versionCode exceeds the Android limit")
    return code


def validate_android_distribution_version_code(
    build_number: int, *, previous_codes: Optional[Mapping[str, int]] = None,
) -> int:
    code = android_distribution_version_code(build_number)
    if build_number < MIN_ANDROID_DISTRIBUTION_BUILD:
        raise ValueError("Android distribution base build must be at least 2129; historical split bases cannot be reused")
    if previous_codes is None:
        previous_codes = {abi: LAST_LEGACY_ANDROID_CODE for abi in ANDROID_RELEASE_ABIS}
    if not isinstance(previous_codes, Mapping) or set(previous_codes) != set(ANDROID_RELEASE_ABIS):
        raise ValueError("Previous distribution baseline must contain all three supported ABIs")
    for abi, previous in previous_codes.items():
        if type(previous) is not int or not 0 < previous <= MAX_ANDROID_VERSION_CODE:
            raise ValueError("Previous distribution versionCode must be a positive integer within the limit")
        if code <= previous:
            raise ValueError(f"Android {abi} distribution versionCode {code} must exceed previous versionCode {previous}")
    return code


def main(
    root: Path = Path(__file__).resolve().parents[1],
    *,
    platform: str = "all",
) -> None:
    if type(platform) is not str or platform not in ("all", "android", "windows"):
        raise SystemExit("Release platform must be all, android or windows")
    match = re.search(
        r"^version:\s*(\d+\.\d+\.\d+(?:-[\w.-]+)?)\+(\d+)\s*$",
        (root / "pubspec.yaml").read_text(), re.M,
    )
    if not match:
        raise SystemExit("pubspec.yaml must contain a semantic version and numeric build number")
    version = match.group(1)
    try:
        distribution_code = validate_android_distribution_version_code(int(match.group(2)))
    except ValueError as error:
        raise SystemExit(str(error)) from error
    ref = os.getenv("GITHUB_REF", "")
    if ref.startswith("refs/tags/") and ref != f"refs/tags/v{version}":
        raise SystemExit(f"Tag {ref} does not match pubspec version v{version}")
    manifest = load_manifest(root)
    if platform != "windows":
        for abi in ANDROID_RELEASE_ABIS:
            for library in ("libsingbox.so", "libtun2socks.so"):
                if not (root / "android/app/src/main/jniLibs" / abi / library).is_file():
                    raise SystemExit(f"Missing native VPN library: {abi}/{library}")
        validate_installed(root, manifest)
    tracked = subprocess.check_output(["git", "ls-files"], cwd=root, text=True).splitlines()
    if any(re.search(r"\.(jks|keystore)(\.|$)", name, re.I) for name in tracked):
        raise SystemExit("Signing keystores must not be tracked in Git")
    expected_codes = ", ".join(
        f"{abi}={distribution_code}" for abi in ANDROID_RELEASE_ABIS
    )
    if platform == "windows":
        print(
            f"Release candidate: v{version}, base build {match.group(2)}; "
            "Windows release metadata and core manifest validated"
        )
    else:
        print(
            f"Release candidate: v{version}, base build {match.group(2)}; "
            f"expected shared Android versionCodes: {expected_codes}; "
            "armeabi-v7a, arm64-v8a and x86_64 native cores present"
        )
    if output := os.getenv("GITHUB_OUTPUT"):
        with open(output, "a", encoding="utf-8") as stream:
            stream.write(f"version={version}\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=("all", "android", "windows"), default="all")
    main(platform=parser.parse_args().platform)
