#!/usr/bin/env python3
"""Inspect local Apple VPN build prerequisites; build only with explicit --build."""
from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT / "scripts") not in sys.path:
    sys.path.insert(0, str(ROOT / "scripts"))
from core_manifest import load_manifest

CORE = load_manifest()["sing_box"]
REVISION = CORE["revision"]
VERSION = CORE["tag"]
FLUTTER_VERSION = "3.41.7"
GROUP = "group.ru.honeyvpn.proxy"
NE = "com.apple.developer.networking.networkextension"
GROUPS = "com.apple.security.application-groups"
TEAM = "com.apple.developer.team-identifier"
HOST = "ru.honeyvpn.proxy.macos"
PROVIDER = HOST + ".PacketTunnel"
TAGS = set(CORE["apple"]["tags"])


class BuildFailure(Exception):
    """A diagnostic safe to print without command output or signing subjects."""


@dataclass
class Check:
    name: str
    ready: bool
    detail: str


def run(command, *, cwd=None, env=None):
    return subprocess.run(command, cwd=cwd, env=env, capture_output=True, timeout=1800)


def require_command(command, message, *, runner=run, cwd=None, env=None):
    try:
        result = runner(command, cwd=cwd, env=env)
    except (OSError, subprocess.TimeoutExpired):
        raise BuildFailure(message) from None
    if result.returncode:
        raise BuildFailure(message)
    return result.stdout


def app_identifier(entitlements):
    return entitlements.get("com.apple.application-identifier", entitlements.get("application-identifier"))


def validate_profile(profile, bundle_id, team_id, *, now=None, certificate=None, device_id=None):
    """Reject a wrong, distribution, expired or under-entitled profile in memory."""
    now = now or datetime.now(timezone.utc)
    expires = profile.get("ExpirationDate")
    if not isinstance(expires, datetime):
        raise BuildFailure("Development profile has no valid expiration date.")
    if expires.tzinfo is None:
        expires = expires.replace(tzinfo=timezone.utc)
    if expires <= now:
        raise BuildFailure("Development profile has expired; refresh it manually in Xcode.")
    if team_id not in profile.get("TeamIdentifier", []):
        raise BuildFailure("Development profile belongs to a different team.")
    entitlements = profile.get("Entitlements", {})
    prefixes = profile.get("ApplicationIdentifierPrefix", [])
    if app_identifier(entitlements) not in {f"{prefix}.{bundle_id}" for prefix in prefixes}:
        raise BuildFailure("Development profile does not authorize this exact bundle identifier.")
    if entitlements.get(TEAM) != team_id:
        raise BuildFailure("Development profile's team entitlement does not match.")
    if "packet-tunnel-provider" not in entitlements.get(NE, []) or GROUP not in entitlements.get(GROUPS, []):
        raise BuildFailure("Development profile must authorize packet-tunnel-provider and the exact shared App Group.")
    # macOS get-task-allow is unrestricted and can be absent from the profile.
    # Development signing is proven by the Apple Development leaf certificate
    # and its membership in this device-bound profile, not an optional key.
    devices = profile.get("ProvisionedDevices", [])
    if profile.get("ProvisionsAllDevices") or not devices:
        raise BuildFailure("Development profile must provision registered Macs.")
    if device_id is not None and device_id not in devices:
        raise BuildFailure("Development profile does not provision this Mac; register it manually in Xcode.")
    if certificate is not None and certificate not in profile.get("DeveloperCertificates", []):
        raise BuildFailure("Signing certificate is not authorized by the embedded development profile.")
    return entitlements


def validate_signed_entitlements(entitlements, authorized, bundle_id, team_id):
    if entitlements.get(TEAM) != team_id or app_identifier(entitlements) != app_identifier(authorized):
        raise BuildFailure("Signed bundle identity/team does not match its provisioning profile.")
    if "packet-tunnel-provider" not in entitlements.get(NE, []) or GROUP not in entitlements.get(GROUPS, []):
        raise BuildFailure("Signed bundle is missing its required Network Extension/App Group entitlement.")
    if entitlements.get("com.apple.security.app-sandbox") is not True:
        raise BuildFailure("Signed host and provider must retain App Sandbox.")


def development_identity_count(output, team_id=None):
    names = re.findall(rb'"(Apple Development:[^"\r\n]+)"', output)
    if team_id:
        names = [name for name in names if name.endswith(f"({team_id})".encode())]
    return len(names)


def decode_profile(path, *, runner=run):
    data = require_command(["/usr/bin/security", "cms", "-D", "-i", str(path)],
                           "Could not verify/decode an existing provisioning profile.", runner=runner)
    try:
        return plistlib.loads(data)
    except (ValueError, plistlib.InvalidFileException):
        raise BuildFailure("Provisioning profile contents are invalid.") from None


def developer_directory(requested, *, runner=run):
    if requested:
        return Path(requested).expanduser().resolve()
    candidates = []
    if os.environ.get("DEVELOPER_DIR"):
        candidates.append(Path(os.environ["DEVELOPER_DIR"]))
    try:
        selected = runner(["/usr/bin/xcode-select", "-p"])
        if selected.returncode == 0:
            candidates.append(Path(selected.stdout.decode().strip()))
    except OSError:
        pass
    candidates.append(Path("/Applications/Xcode.app/Contents/Developer"))
    return next((p for p in candidates if (p / "usr/bin/xcodebuild").is_file()), candidates[-1])


def native_architecture(*, runner=run):
    try:
        probe = require_command(["/usr/sbin/sysctl", "-n", "hw.optional.arm64"],
                                "Could not inspect hardware architecture.", runner=runner)
        return "arm64" if probe.strip() == b"1" else "x86_64"
    except BuildFailure:
        # An arm64 process cannot be a translated Intel process. This read-only
        # fallback also works when a host sandbox denies the hardware sysctl.
        machine = require_command(["/usr/bin/uname", "-m"], "Could not inspect process architecture.", runner=runner).strip()
        if machine == b"arm64":
            return "arm64"
        translated = runner(["/usr/sbin/sysctl", "-n", "sysctl.proc_translated"])
        if translated.returncode == 0 and translated.stdout.strip() == b"1":
            return "arm64"
        if machine == b"x86_64" and b"unknown oid" in translated.stderr.lower():
            return "x86_64"
        raise BuildFailure("Cannot confirm native architecture; run this read-only check outside the restricting sandbox.") from None


def local_device_id(*, runner=run):
    output = require_command(["/usr/sbin/system_profiler", "SPHardwareDataType", "-json"],
                             "Could not inspect this Mac's provisioning identifier.", runner=runner)
    try:
        hardware = json.loads(output)["SPHardwareDataType"][0]
        identifier = hardware.get("provisioning_udid") or hardware.get("platform_UUID")
        if not isinstance(identifier, str) or not identifier:
            raise ValueError()
        return identifier
    except (KeyError, ValueError, IndexError):
        raise BuildFailure("Cannot find this Mac's provisioning UDID; inspect System Information manually.") from None


def validate_staged_core(root, arch, *, runner=run):
    directory = root / "macos/Frameworks"
    metadata = json.loads((directory / "apple-core-build.json").read_text())
    if metadata.get("revision") != REVISION or metadata.get("base_version") != VERSION or set(metadata.get("tags", [])) != TAGS:
        raise BuildFailure("Staged Libbox provenance does not match the reviewed pin/features.")
    if metadata.get("repository") != CORE["repository"] or metadata.get("go") != CORE["apple"]["go"] or metadata.get("gomobile") != CORE["apple"]["gomobile"]:
        raise BuildFailure("Staged Libbox provenance toolchain/repository does not match.")
    if not re.fullmatch(r"[0-9a-f]{64}", metadata.get("prepared_builder_sha256", "")):
        raise BuildFailure("Staged Libbox provenance is missing its prepared source checksum.")
    framework = directory / "Libbox.xcframework"
    info = plistlib.loads((framework / "Info.plist").read_bytes())
    slices = [item for item in info["AvailableLibraries"] if item.get("SupportedPlatform") == "macos" and not item.get("SupportedPlatformVariant")]
    if len(slices) != 1:
        raise BuildFailure("Stage the reviewed universal macOS Libbox framework.")
    item = slices[0]
    if not re.fullmatch(r"[a-zA-Z0-9_-]+", item.get("LibraryIdentifier", "")) or item.get("LibraryPath") != "Libbox.framework":
        raise BuildFailure("Staged framework has an unexpected layout.")
    if set(item.get("SupportedArchitectures", [])) != {"arm64", "x86_64"}:
        raise BuildFailure("Staged framework must contain the reviewed universal macOS slice.")
    libbox = framework / item["LibraryIdentifier"] / "Libbox.framework"
    if not libbox.resolve().is_relative_to(framework.resolve()):
        raise BuildFailure("Staged framework must not resolve outside its own container.")
    architectures = require_command(["/usr/bin/lipo", "-archs", str(libbox / "Libbox")], "Staged Libbox binary cannot be inspected.", runner=runner).decode().split()
    if arch not in architectures or set(architectures) != {"arm64", "x86_64"}:
        raise BuildFailure("Staged binary architectures do not match its metadata.")
    for name in ("Libbox.h", "Libbox.objc.h", "Universe.objc.h", "ref.h"):
        if not (libbox / "Headers" / name).is_file():
            raise BuildFailure("Staged framework is missing generated public headers.")
    api = (libbox / "Headers/Libbox.objc.h").read_text()
    for symbol in ("LibboxNewCommandServer", "LibboxGetTunnelFileDescriptor", "LibboxSetup", "LibboxCheckConfig"):
        if symbol not in api:
            raise BuildFailure("Staged framework headers do not expose the pinned API.")
    config = (directory / "Libbox.xcconfig").read_text()
    if "HONEYPROXY_LIBBOX_VALIDATED" not in config or "-framework Libbox" not in config:
        raise BuildFailure("Run reviewed framework staging manually to generate its linkage configuration.")


def preflight(root, team_id, developer_dir, flutter, *, runner=run, system=None, machine=None, profile_dirs=None):
    checks = []
    system = system or platform.system()
    if system != "Darwin":
        return [Check("macOS", False, "Run this helper on the Mac used for development.")], None
    env = dict(os.environ, DEVELOPER_DIR=str(developer_dir), FLUTTER_SUPPRESS_ANALYTICS="true", COCOAPODS_DISABLE_STATS="true", CI="true")
    try:
        arch = native_architecture(runner=runner)
        if (machine or platform.machine()) != arch:
            raise BuildFailure("Run a native Python interpreter, not Rosetta, for native-architecture verification.")
        checks.append(Check("Native architecture", True, arch))
    except BuildFailure as error:
        checks.append(Check("Native architecture", False, str(error)))
        arch = None
    full_xcode = (developer_dir / "usr/bin/xcodebuild").is_file()
    checks.append(Check("Full Xcode", full_xcode, "Full Xcode selected." if full_xcode else "Install/open full Xcode; use --developer-dir for its Contents/Developer directory."))
    if full_xcode:
        result = runner([str(developer_dir / "usr/bin/xcodebuild"), "-checkFirstLaunchStatus"], env=env)
        checks.append(Check("Xcode first launch", result.returncode == 0, "Complete." if result.returncode == 0 else "Open Xcode yourself, review its license and finish first launch; no license is accepted by this helper."))
    try:
        identities = require_command(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"], "Cannot inspect valid development identities in the local Keychain.", runner=runner)
        count = development_identity_count(identities, team_id)
        checks.append(Check("Apple Development identities", count > 0, f"Valid matching identities: {count}." if team_id else f"Valid identities: {count}. Select a paid team in Xcode if none."))
    except BuildFailure as error:
        checks.append(Check("Apple Development identities", False, str(error)))
    try:
        validate_staged_core(root, arch, runner=runner)
        checks.append(Check("Pinned Libbox staging", True, "Reviewed framework, metadata and headers are present."))
    except (BuildFailure, OSError, ValueError, KeyError, TypeError, plistlib.InvalidFileException) as error:
        detail = str(error) if isinstance(error, BuildFailure) else "Stage the verified CI framework/provenance with scripts/prepare_apple_framework.py; preflight never stages or downloads it."
        checks.append(Check("Pinned Libbox staging", False, detail))
    sdk_version = flutter.parent / "cache/flutter.version.json" if flutter else None
    try:
        sdk_ready = bool(flutter and flutter.is_file() and sdk_version and sdk_version.is_file() and json.loads(sdk_version.read_text()).get("frameworkVersion") == FLUTTER_VERSION)
    except (OSError, ValueError, TypeError):
        sdk_ready = False
    checks.append(Check("Pinned Flutter", sdk_ready, "Flutter 3.41.7 cache present." if sdk_ready else "Use --flutter with an installed Flutter 3.41.7 executable; preflight does not invoke/bootstrap Flutter."))
    checks.append(Check("Dart lockfile", (root / "pubspec.lock").is_file(), "pubspec.lock required; explicit build uses --enforce-lockfile."))
    try:
        source_info = plistlib.loads((root / "macos/HoneyProxyPacketTunnel/Info.plist").read_bytes())
        readiness = source_info.get("HoneyProxyCoreReady") is False and source_info.get("HoneyProxyCoreRevision") == REVISION
    except (OSError, ValueError, plistlib.InvalidFileException):
        readiness = False
    checks.append(Check("Source readiness gate", readiness, "CoreReady must remain false with the reviewed revision; do not edit it to enable local VPN."))
    if (root / "macos/Podfile").exists():
        pods_ready = (root / "macos/Podfile.lock").is_file() and shutil.which("pod") is not None
        checks.append(Check("CocoaPods lock", pods_ready, "A working pod and Podfile.lock are required; build uses --deployment."))
    if team_id:
        matched = {HOST: 0, PROVIDER: 0}
        try:
            device = local_device_id(runner=runner)
            directories = profile_dirs or [Path.home() / "Library/MobileDevice/Provisioning Profiles", Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"]
            for directory in directories:
                for path in directory.glob("*"):
                    if path.suffix not in (".provisionprofile", ".mobileprovision"):
                        continue
                    try:
                        profile = decode_profile(path, runner=runner)
                        for identifier in matched:
                            try:
                                validate_profile(profile, identifier, team_id, device_id=device)
                                matched[identifier] += 1
                            except BuildFailure:
                                pass
                    except BuildFailure:
                        pass
            checks.append(Check("Registered Mac development profiles", all(matched.values()), f"Matching host profiles: {matched[HOST]}; provider profiles: {matched[PROVIDER]}. Create/refresh both in Xcode with Network Extensions and App Groups."))
        except BuildFailure as error:
            checks.append(Check("Registered Mac development profiles", False, str(error)))
    else:
        checks.append(Check("Development team/profiles", False, "Supply a paid 10-character --team-id to check profiles for this Mac; no account changes are made."))
    return checks, env


def build_commands(root, flutter, developer_dir, team_id, arch):
    return [
        [str(flutter), "pub", "get", "--enforce-lockfile"],
        [str(flutter), "build", "macos", "--debug", "--config-only", "--no-pub"],
        [str(developer_dir / "usr/bin/xcodebuild"), "-workspace", "macos/Runner.xcworkspace", "-scheme", "Runner", "-configuration", "Debug", "-destination", "platform=macOS,arch=" + arch, "-derivedDataPath", str(root / "build/macos-local-development"), "ARCHS=" + arch, "ONLY_ACTIVE_ARCH=YES", "CODE_SIGNING_ALLOWED=YES", "CODE_SIGNING_REQUIRED=YES", "CODE_SIGN_IDENTITY=Apple Development", "DEVELOPMENT_TEAM=" + team_id, "SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG HONEYPROXY_DEVELOPMENT_VPN", "build"],
    ]


def verify_development_bundle(app, metadata, team_id, *, runner=run, device_id=None):
    require_command([sys.executable, str(ROOT / "scripts/validate_apple_bundle.py"), str(app), str(metadata), "--verify-only", "--local-development"], "Pinned core bundle verification failed; the signed bundle was not modified.", runner=runner)
    for bundle, identifier in ((app, HOST), (app / "Contents/PlugIns/HoneyProxyPacketTunnel.appex", PROVIDER)):
        require_command(["/usr/bin/codesign", "--verify", "--strict", "-R", "anchor apple generic", str(bundle)], "Apple-anchored strict code-signature verification failed.", runner=runner)
        info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
        if info.get("CFBundleIdentifier") != identifier:
            raise BuildFailure("Built host/provider has an unexpected bundle identifier.")
        # codesign display writes to stderr, retained only in memory.
        displayed = runner(["/usr/bin/codesign", "-dv", "--verbose=4", str(bundle)])
        if displayed.returncode:
            raise BuildFailure("Cannot inspect the development signature.")
        details = displayed.stdout + displayed.stderr
        if b"Authority=Apple Development:" not in details or f"TeamIdentifier={team_id}".encode() not in details:
            raise BuildFailure("Bundle must use an Apple Development identity from the requested team.")
        entitlements = plistlib.loads(require_command(["/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", str(bundle)], "Cannot inspect signed bundle entitlements.", runner=runner))
        profile = decode_profile(bundle / "Contents/embedded.provisionprofile", runner=runner)
        with tempfile.TemporaryDirectory(prefix="honeyproxy-public-cert-") as temporary:
            prefix = Path(temporary) / "certificate"
            require_command(["/usr/bin/codesign", "-d", "--extract-certificates", str(prefix), str(bundle)], "Cannot inspect the public signing certificate.", runner=runner)
            certificate = Path(str(prefix) + "0").read_bytes()
        authorized = validate_profile(profile, identifier, team_id, certificate=certificate, device_id=device_id)
        validate_signed_entitlements(entitlements, authorized, identifier, team_id)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", action="store_true", help="Explicitly prepare dependencies and build/sign local Debug; never installs or starts VPN")
    parser.add_argument("--team-id", help="Existing paid developer team, 10 uppercase letters/digits")
    parser.add_argument("--developer-dir", help="Full Xcode Contents/Developer directory; does not change xcode-select")
    parser.add_argument("--flutter", help="Installed pinned Flutter executable")
    args = parser.parse_args(argv)
    if args.team_id is not None and not re.fullmatch(r"[A-Z0-9]{10}", args.team_id):
        parser.error("Team ID must be 10 uppercase letters/digits.")
    if args.build and not args.team_id:
        parser.error("--build requires an existing paid --team-id.")
    flutter_path = args.flutter or shutil.which("flutter")
    flutter = Path(flutter_path).expanduser().resolve() if flutter_path else None
    developer = developer_directory(args.developer_dir)
    try:
        checks, env = preflight(ROOT, args.team_id, developer, flutter)
    except (OSError, subprocess.TimeoutExpired, ValueError, KeyError, TypeError):
        print("ERROR — A local prerequisite could not be inspected; no build/account operation performed.", file=sys.stderr)
        return 2
    for check in checks:
        print(f"{'OK' if check.ready else 'MISSING'} — {check.name}: {check.detail}")
    print("Preflight does not sign, register, stage, accept licenses or test VPN traffic.")
    if not all(check.ready for check in checks):
        return 2
    if not args.build:
        print("Prerequisites appear ready. No build performed; use explicit --build to continue.")
        return 0
    try:
        arch = native_architecture()
        commands = build_commands(ROOT, flutter, developer, args.team_id, arch)
        for command, label in zip(commands[:2], ["locked Dart dependencies", "Flutter Debug configuration"]):
            print("Preparing " + label + "…")
            require_command(command, "Preparation failed for " + label + "; inspect the project locally. No signing/account credentials are printed.", cwd=ROOT, env=env)
        if (ROOT / "macos/Podfile").exists():
            if not (ROOT / "macos/Podfile.lock").is_file():
                raise BuildFailure("CocoaPods now requires a reviewed Podfile.lock; prepare it manually before retrying.")
            require_command(["pod", "install", "--deployment"], "Locked CocoaPods preparation failed; inspect it locally.", cwd=ROOT / "macos", env=env)
        print("Building development-signed native Debug app…")
        require_command(commands[2], "Debug signing/build failed. Select the paid team and provision both targets manually in Xcode; this helper never requests account/profile updates.", cwd=ROOT, env=env)
        app = ROOT / "build/macos-local-development/Build/Products/Debug/HoneyProxyUtility.app"
        verify_development_bundle(app, ROOT / "macos/Frameworks/apple-core-build.json", args.team_id, device_id=local_device_id())
        print("Development-signed host/provider and pinned core verified. Source readiness remains false.")
        print("App: " + str(app))
        print("No VPN traffic test was performed. Signed routing, DNS, counters and failure tests remain required.")
        return 0
    except (BuildFailure, OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired, plistlib.InvalidFileException) as error:
        print("ERROR — " + (str(error) if isinstance(error, BuildFailure) else "Build verification could not inspect the expected artifacts."), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
