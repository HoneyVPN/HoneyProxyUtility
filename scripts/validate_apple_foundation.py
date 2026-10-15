"""Validate the macOS UI/Network Extension foundation without enabling a VPN."""
from pathlib import Path
import plistlib
import re
from core_manifest import load_manifest

root = Path(__file__).resolve().parents[1]
macos = root / "macos"
core = load_manifest(root)["sing_box"]
project = (macos / "Runner.xcodeproj/project.pbxproj").read_text()
version = re.search(r"^version:\s*(\d+\.\d+\.\d+)(?:-[\w.-]+)?\+(\d+)\s*$", (root / "pubspec.yaml").read_text(), re.M)
assert version, "Missing Flutter app version"
provider_configs = re.findall(r"buildSettings = \{([^{}]*INFOPLIST_FILE = HoneyProxyPacketTunnel/Info\.plist;[^{}]*)\}", project)
assert len(provider_configs) == 3, "Missing packet-provider build configurations"
for config in provider_configs:
    native_version = re.search(r"\bMARKETING_VERSION\s*=\s*([^;]+);", config)
    native_build = re.search(r"\bCURRENT_PROJECT_VERSION\s*=\s*([^;]+);", config)
    assert native_version and native_version.group(1).strip() == version.group(1), "Update all packet-provider MARKETING_VERSION values to match pubspec.yaml"
    assert native_build and native_build.group(1).strip() == version.group(2), "Update all packet-provider CURRENT_PROJECT_VERSION values to match pubspec.yaml"
provider = plistlib.loads((macos / "HoneyProxyPacketTunnel/Info.plist").read_bytes())
assert provider["HoneyProxyCoreReady"] is False, "Foundation must not advertise an integrated core"
assert provider["HoneyProxyCoreRevision"] == core["revision"]
assert core["revision"] in (macos / "Runner/AppleVpnController.swift").read_text(), "Host revision gate must match the manifest"
assert core["version"] in (macos / "HoneyProxyPacketTunnel/PacketTunnelProvider.swift").read_text(), "Provider version gate must match the manifest"
assert core["version"] in (root / "test/native/apple_core_configuration_check.swift").read_text(), "Native schema check must match the manifest"
assert provider["NSExtension"]["NSExtensionPointIdentifier"] == "com.apple.networkextension.packet-tunnel"
assert provider["NSExtension"]["NSExtensionPrincipalClass"] == "$(PRODUCT_MODULE_NAME).PacketTunnelProvider"
for name in ("Runner/DebugProfile.entitlements", "Runner/Release.entitlements", "HoneyProxyPacketTunnel/HoneyProxyPacketTunnel.entitlements"):
    entitlements = plistlib.loads((macos / name).read_bytes())
    assert entitlements["com.apple.security.app-sandbox"] is True
    assert entitlements["com.apple.security.network.client"] is True
    assert entitlements["com.apple.developer.networking.networkextension"] == ["packet-tunnel-provider"]
    assert entitlements["com.apple.security.application-groups"] == ["group.ru.honeyvpn.proxy"]
for name in ("AppleVpnController.swift", "AppleVpnChannels.swift", "PacketTunnelProvider.swift", "LibboxPlatformAdapter.swift", "TunnelNetworkSettingsMapper.swift", "TunnelSettingsCoordinator.swift", "OwnedSessionConfiguration.swift", "AppleVpnStatusSnapshot.swift", "AppleProviderStatus.swift", "LibboxCounterStream.swift", "DevelopmentVpnGate.swift"):
    assert f"{name} in Sources" in project, f"Native source not wired: {name}"
assert 'productType = "com.apple.product-type.app-extension"' in project
assert "HoneyProxyPacketTunnel.appex in Embed App Extensions" in project
assert project.count("baseConfigurationReference = 48A700000000000000000035;") == 3
declared = re.findall(r"^\t\t([A-F0-9]{24})\s*(?:/\*.*?\*/)?\s*=\s*\{", project, re.M)
assert len(declared) == len(set(declared)), "Duplicate Xcode object identifiers"
referenced = set(re.findall(r"\b[A-F0-9]{24}\b", project))
assert referenced <= set(declared), f"Unresolved Xcode objects: {referenced - set(declared)}"
channels = (macos / "Runner/AppleVpnChannels.swift").read_text()
assert "ru.honeyvpn.proxy/apple_vpn" in channels
assert "ru.honeyvpn.proxy/apple_vpn_status" in channels
for method in ("initialize", "requestPermission", "start", "stop", "checkStatus", "getStatus"):
    assert f'case "{method}"' in channels
assert plistlib.loads((macos / "Runner/Info.plist").read_bytes())["NSCameraUsageDescription"]
print("Apple foundation valid: native target/channel/entitlements wired; VPN core remains unavailable.")
print("This check does not verify signing, native compilation, or traffic forwarding.")
