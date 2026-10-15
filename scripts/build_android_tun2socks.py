#!/usr/bin/env python3
"""Reproduce static tun2socks cores with the locked Go compiler and page alignment."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

from validate_android_cores import CoreValidationError, ROOT, load_lock, inspect_executable, validate_binary


def command(arguments: list[str], *, cwd: Path | None = None, env: dict | None = None) -> str:
    result = subprocess.run(arguments, cwd=cwd, env=env, text=True, capture_output=True, timeout=1800)
    if result.returncode:
        raise CoreValidationError(f"Build command failed: {result.stderr[-2000:]}")
    return result.stdout.strip()


def build(lock: dict, source: Path, go: Path, output: Path) -> dict:
    pin = lock["tun2socks"]
    if command(["git", "rev-parse", "HEAD"], cwd=source) != pin["revision"]:
        raise CoreValidationError("tun2socks source checkout does not match the reviewed revision")
    if command(["git", "status", "--porcelain", "--untracked-files=all"], cwd=source):
        raise CoreValidationError("tun2socks source must be clean, including untracked files")
    if command(["git", "rev-parse", pin["tag"] + "^{commit}"], cwd=source) != pin["revision"]:
        raise CoreValidationError("tun2socks tag does not match the reviewed revision")
    output.mkdir(parents=True, exist_ok=True)
    records = {}
    for key in ("linux-arm64", "linux-amd64"):
        asset = pin["assets"][key]
        recipe = asset["build"]
        source_sum = hashlib.sha256((source / "go.sum").read_bytes()).hexdigest()
        if recipe.get("source_go_sum_sha256", source_sum) != source_sum:
            raise CoreValidationError("tun2socks source dependency checksum does not match the locked recipe")
        env = dict(os.environ, GOTOOLCHAIN="local", CGO_ENABLED="0", GOOS="linux",
                   GOARCH=asset["expected_goarch"], GOAMD64="v1", GOARM64="v8.0",
                   GOPATH=str(output / "go-path"), GOMODCACHE=str(output / "go-modules"),
                   GOCACHE=str(output / "go-cache"))
        actual_go = command([str(go), "env", "GOVERSION"], env=env)
        if actual_go != "go" + recipe["go"]:
            raise CoreValidationError("Go compiler does not match the locked tun2socks recipe")
        alignment = recipe["alignment"]
        if alignment not in (16384, 65536):
            raise CoreValidationError("Unsupported tun2socks page alignment recipe")
        name = recipe["output_name"]
        if name != "tun2socks-" + key:
            raise CoreValidationError("Unexpected tun2socks output filename")
        ldflags = (f"-s -w -buildid= -R {alignment} "
                   f"-X github.com/xjasonlyu/tun2socks/v2/internal/version.Version={pin['tag']} "
                   f"-X github.com/xjasonlyu/tun2socks/v2/internal/version.GitCommit={pin['revision']}")
        target = output / name
        command([str(go), "build", "-mod=readonly", "-trimpath", "-buildvcs=true", "-ldflags", ldflags, "-o", str(target), "."], cwd=source, env=env)
        data = target.read_bytes()
        info = inspect_executable(data)
        if info["build"].get("vcs.revision") != pin["revision"] or info["build"].get("vcs.modified") != "false":
            raise CoreValidationError("Built tun2socks provenance does not match the clean reviewed source")
        if min(info["load_alignments"]) < alignment or info["needed"] or info["interpreter"] is not None:
            raise CoreValidationError("Built tun2socks page alignment/static linkage is invalid")
        if asset.get("installed_sha256"):
            validate_binary(data, "tun2socks", pin, asset)
        records[key] = {"installed_sha256": hashlib.sha256(data).hexdigest(), "size": len(data),
                        "go_version": info["go_version"], "module": info["module"],
                        "load_alignments": info["load_alignments"], "build": recipe, "ldflags": ldflags,
                        "source_revision": pin["revision"], "source_go_sum_sha256": source_sum}
    (output / "tun2socks-build.json").write_text(json.dumps(records, indent=2) + "\n")
    return records


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lock", type=Path, default=ROOT / "core-lock.json")
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--go", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(build(load_lock(args.lock), args.source.resolve(), args.go.resolve(), args.output_dir.resolve()), indent=2))
    except (CoreValidationError, KeyError, OSError, ValueError, subprocess.TimeoutExpired) as exc:
        parser.exit(1, f"tun2socks build failed: {exc}\n")


if __name__ == "__main__":
    main()
