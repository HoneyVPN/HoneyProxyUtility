"""Prepare a documented feature subset of the exact pinned public libbox source."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
from core_manifest import load_manifest

source = Path(sys.argv[1]).resolve()
core = load_manifest()["sing_box"]
apple = core["apple"]
revision = core["revision"]
actual = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
if actual != revision:
    raise SystemExit(f"Unexpected libbox revision: {actual}")
builder = source / "cmd/internal/build_libbox/main.go"
content = builder.read_text()
expected = 'sharedTags = append(sharedTags, "with_gvisor", "with_quic", "with_wireguard", "with_masque", "with_mtproxy", "with_utls", "with_naive_outbound", "with_clash_api", "badlinkname", "tfogo_checklinkname0")'
tailscale = 'sharedTags = append(sharedTags, "with_tailscale", "ts_omit_logtail", "ts_omit_ssh", "ts_omit_drive", "ts_omit_taildrop", "ts_omit_webclient", "ts_omit_doctor", "ts_omit_capture", "ts_omit_kube", "ts_omit_aws", "ts_omit_synology", "ts_omit_bird")'
if content.count(expected) != 1 or content.count(tailscale) != 1:
    raise SystemExit("Pinned Apple build-tag layout changed; review the feature set before building")
tags = ["with_gvisor", "with_quic", "with_wireguard", "with_utls", "with_clash_api", "badlinkname", "tfogo_checklinkname0"]
if apple["tags"] != tags + ["with_dhcp", "grpcnotrace"]:
    raise SystemExit("Apple core feature policy changed; review it before modifying the builder")
replacement = "sharedTags = append(sharedTags, " + ", ".join(json.dumps(tag) for tag in tags) + ")"
content = content.replace(expected, replacement).replace(tailscale, "// HoneyProxy Apple preview excludes Tailscale and Naive/Cronet.")
builder.write_text(content)
metadata = {
    "repository": core["repository"],
    "revision": revision,
    "base_version": core["tag"],
    "go": apple["go"],
    "gomobile": apple["gomobile"],
    "tags": apple["tags"],
    "prepared_builder_sha256": hashlib.sha256(builder.read_bytes()).hexdigest(),
    "purpose": "unsigned macOS framework and generated headers; signed routing remains unverified",
}
(source / "apple-core-build.json").write_text(json.dumps(metadata, indent=2) + "\n")
print(json.dumps(metadata, indent=2))
