"""Stage the pinned static macOS framework without enabling VPN readiness."""
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
from core_manifest import load_manifest


def validate_public_headers(framework: Path) -> None:
    headers = framework / "Headers"
    for name in ("Libbox.h", "Libbox.objc.h", "Universe.objc.h", "ref.h"):
        assert (headers / name).is_file(), f"Missing public framework header {name}"
    # gomobile v0.1.12 emits an umbrella header that includes the generated API.
    umbrella = (headers / "Libbox.h").read_text()
    assert re.search(r'#\s*(?:include|import)\s+["<]Libbox\.objc\.h[">]', umbrella), "Umbrella does not include the generated Libbox API"
    api = (headers / "Libbox.objc.h").read_text()
    for symbol in ("LibboxNewCommandServer", "LibboxGetTunnelFileDescriptor", "LibboxSetup", "LibboxCheckConfig"):
        assert re.search(r"FOUNDATION_EXPORT\s+[^;]+\b" + symbol + r"\s*\(", api), f"Missing pinned API declaration {symbol}"
    for protocol in ("LibboxPlatformInterface", "LibboxCommandServerHandler", "LibboxTunOptions"):
        assert re.search(r"@protocol\s+" + protocol + r"\s*<NSObject>", api), f"Missing pinned protocol {protocol}"


root = Path(__file__).resolve().parents[1]
source = Path(sys.argv[1]).resolve()
metadata_path = Path(sys.argv[2]).resolve()
metadata = json.loads(metadata_path.read_text())
core = load_manifest()["sing_box"]
revision = core["revision"]
assert metadata["revision"] == revision, "Unexpected core source revision"
assert metadata["base_version"] == core["tag"]
assert metadata["repository"] == core["repository"]
assert metadata["go"] == core["apple"]["go"] and metadata["gomobile"] == core["apple"]["gomobile"], "Unexpected binding toolchain"
required = set(core["apple"]["tags"])
assert set(metadata["tags"]) == required, "Unexpected core features"
info = plistlib.loads((source / "Info.plist").read_bytes())
slices = [item for item in info["AvailableLibraries"] if item["SupportedPlatform"] == "macos" and not item.get("SupportedPlatformVariant")]
assert len(slices) == 1 and set(slices[0]["SupportedArchitectures"]) == {"arm64", "x86_64"}, "Expected universal macOS framework"
item = slices[0]
assert re.fullmatch(r"[a-zA-Z0-9_-]+", item["LibraryIdentifier"])
assert item["LibraryPath"] == "Libbox.framework"
framework = source / item["LibraryIdentifier"] / item["LibraryPath"]
binary = framework / "Libbox"
assert binary.is_file(), "Missing static framework binary"
validate_public_headers(framework)
archs = subprocess.check_output(["lipo", "-archs", str(binary)], text=True).split()
assert set(archs) == {"arm64", "x86_64"}, "Framework binary architecture mismatch"
destination = root / "macos/Frameworks"
destination.mkdir(exist_ok=True)
target = destination / "Libbox.xcframework"
if target.exists():
    shutil.rmtree(target)
shutil.copytree(source, target, symlinks=True)
shutil.copyfile(metadata_path, destination / "apple-core-build.json")
search = "$(PROJECT_DIR)/Frameworks/Libbox.xcframework/" + item["LibraryIdentifier"]
(destination / "Libbox.xcconfig").write_text(
    '// Generated from pinned universal macOS framework; readiness remains false.\n'
    f'FRAMEWORK_SEARCH_PATHS = $(inherited) "{search}"\n'
    'OTHER_LDFLAGS = $(inherited) -framework Libbox -framework Security -framework CoreFoundation -lresolv\n'
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS = $(inherited) HONEYPROXY_LIBBOX_VALIDATED\n'
)
print("Pinned static Libbox staged for compilation. HoneyProxyCoreReady remains false.")
