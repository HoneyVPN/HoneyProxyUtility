"""Verify an unsigned, core-linked preview without declaring VPN runtime ready."""
import json
from pathlib import Path
import plistlib
import subprocess
import argparse
import platform
from core_manifest import load_manifest

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("app")
parser.add_argument("metadata")
parser.add_argument("--verify-only", action="store_true", help="Do not modify a signed bundle")
parser.add_argument("--local-development", action="store_true", help="Accept only this Mac's native architecture for local Debug QA")
args = parser.parse_args()
if args.local_development and not args.verify_only:
    parser.error("Local development requires --verify-only to preserve the signature")
app = Path(args.app).resolve()
metadata = json.loads(Path(args.metadata).read_text())
core = load_manifest()["sing_box"]
assert metadata["base_version"] == core["tag"] and metadata["repository"] == core["repository"]
assert set(metadata["tags"]) == set(core["apple"]["tags"])
assert metadata["go"] == core["apple"]["go"] and metadata["gomobile"] == core["apple"]["gomobile"]
provider = app / "Contents/PlugIns/HoneyProxyPacketTunnel.appex"
info = plistlib.loads((provider / "Contents/Info.plist").read_bytes())
assert info["CFBundleIdentifier"] == "ru.honeyvpn.proxy.macos.PacketTunnel"
assert info["HoneyProxyCoreReady"] is False, "Unsigned preview must remain unavailable"
assert info["HoneyProxyCoreRevision"] == metadata["revision"] == core["revision"]
binary = provider / "Contents/MacOS" / info["CFBundleExecutable"]
architectures = set(subprocess.check_output(["lipo", "-archs", str(binary)], text=True).split())
if args.local_development:
    assert platform.machine() in architectures and architectures <= {"arm64", "x86_64"}
else:
    assert architectures == {"arm64", "x86_64"}
symbols = subprocess.check_output(["nm", "-gU", str(binary)], text=True)
for symbol in ("_LibboxNewCommandServer", "_LibboxGetTunnelFileDescriptor", "_LibboxSetup"):
    assert symbol in symbols, f"Pinned core was not linked: {symbol}"
if not args.verify_only:
    resources = provider / "Contents/Resources"
    resources.mkdir(exist_ok=True)
    (resources / "apple-core-build.json").write_text(json.dumps(metadata, indent=2) + "\n")
print("Provider architectures and pinned Libbox linkage verified. Release readiness remains false; signed traffic tests are still required.")
