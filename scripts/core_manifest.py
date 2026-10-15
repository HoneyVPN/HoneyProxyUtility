"""Read the reviewed, immutable core selection shared by all build paths."""
import json
from pathlib import Path
import re
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
SING_BOX_REPOSITORY = "https://github.com/shtorm-7/sing-box-extended"
TUN2SOCKS_REPOSITORY = "https://github.com/xjasonlyu/tun2socks"
_IDENTITY_FIELDS = frozenset(("version", "tag", "revision"))
_ASSET_FIELDS = frozenset((
    "url", "archive_sha256", "archive_member", "archive_bytes",
    "installed_sha256", "installed_bytes", "expected_goos", "expected_goarch",
    "go_version", "minimum_load_alignment", "runtime_assets", "build",
    "version", "tag", "revision", "vcs_modified", "provenance_note", "selection_reason",
))
_PLATFORMS = {
    SING_BOX_REPOSITORY: frozenset(("android-armv7", "android-arm64", "android-amd64", "linux-amd64", "windows-amd64", "linux-amd64-android-checker")),
    TUN2SOCKS_REPOSITORY: frozenset(("linux-armv7", "linux-arm64", "linux-amd64")),
}


def _validate_identity(metadata, repository):
    if not isinstance(metadata.get("version"), str) or not re.fullmatch(r"\d+\.\d+\.\d+(?:-extended-\d+\.\d+\.\d+)?", metadata["version"]):
        raise ValueError("Core version must be a reviewed stable release")
    if metadata["repository"] != repository or metadata["tag"] != "v" + metadata["version"]:
        raise ValueError("Unexpected core repository/version")
    if not isinstance(metadata.get("revision"), str) or not re.fullmatch(r"[0-9a-f]{40}", metadata["revision"]):
        raise ValueError("Core source revision must be immutable")


def resolve_asset_metadata(core, platform):
    """Resolve a reviewed asset pin without changing other platforms' defaults."""
    repository = core["repository"]
    if repository not in _PLATFORMS or platform not in _PLATFORMS[repository]:
        raise ValueError("Unreviewed core asset platform")
    asset = core["assets"][platform]
    if not isinstance(asset, dict) or set(asset) - _ASSET_FIELDS:
        raise ValueError("Unreviewed core asset fields")
    overrides = _IDENTITY_FIELDS.intersection(asset)
    if overrides:
        if repository != SING_BOX_REPOSITORY or platform not in ("windows-amd64", "android-armv7", "android-arm64", "android-amd64", "linux-amd64-android-checker"):
            raise ValueError("Core identity overrides are reviewed only for Windows/Android sing-box and its quality checker")
        if overrides != _IDENTITY_FIELDS:
            raise ValueError("Core asset version, tag and revision must be overridden together")
    metadata = {"repository": repository, **{field: core[field] for field in _IDENTITY_FIELDS}, **asset}
    _validate_identity(metadata, repository)
    for field in ("archive_bytes", "installed_bytes"):
        if field in asset and (type(asset[field]) is not int or not 0 < asset[field] < 150 * 1024 * 1024):
            raise ValueError("Core asset size must be a reviewed bounded byte count")
    if "vcs_modified" in asset and type(asset["vcs_modified"]) is not bool:
        raise ValueError("Core asset source-tree provenance must be explicit")
    for field in ("provenance_note", "selection_reason"):
        if field in asset and (not isinstance(asset[field], str) or not asset[field].strip()):
            raise ValueError("Core asset provenance and selection notes must be nonempty")
    return metadata


def validate_manifest(manifest):
    """Validate the same immutable identities for default and custom lock files."""
    if manifest.get("schema_version") != 1:
        raise ValueError("Unsupported core manifest format")
    for name, repository in (("sing_box", SING_BOX_REPOSITORY),
                             ("tun2socks", TUN2SOCKS_REPOSITORY)):
        core = manifest[name]
        _validate_identity(core, repository)
        for platform in core["assets"]:
            asset = resolve_asset_metadata(core, platform)
            if not isinstance(asset.get("installed_sha256"), str) or not re.fullmatch(r"[0-9a-f]{64}", asset["installed_sha256"]):
                raise ValueError("Missing reviewed core binary checksum")
            if "build" not in asset:
                if not isinstance(asset.get("archive_sha256"), str) or not re.fullmatch(r"[0-9a-f]{64}", asset["archive_sha256"]):
                    raise ValueError("Missing reviewed core archive checksum")
                prefix = repository + "/releases/download/" + asset["tag"] + "/"
                parsed = urlsplit(asset["url"])
                expected = urlsplit(prefix)
                basename = parsed.path.removeprefix(expected.path)
                if parsed.scheme != "https" or parsed.netloc != expected.netloc or parsed.query or parsed.fragment \
                        or not parsed.path.startswith(expected.path) \
                        or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]+", basename) \
                        or basename in (".", ".."):
                    raise ValueError("Core download does not match its pinned release")
    return manifest


def load_manifest(root=None):
    return validate_manifest(json.loads((Path(root or ROOT) / "core-lock.json").read_text()))
