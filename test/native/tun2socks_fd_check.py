#!/usr/bin/env python3
"""Exercise the real Linux executable's CLI and inherited FD without a VPN/TUN."""
import argparse
import platform
import signal
import socket
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary")
    parser.add_argument("--version", default="2.7.0")
    parser.add_argument("--revision", default="8dda19e8e4613e014f0b12f3e624fdff5e5f23b3")
    args = parser.parse_args()
    if platform.system() != "Linux":
        parser.error("Run this inherited-FD smoke check on Linux")
    version = subprocess.run([args.binary, "--version"], check=True, capture_output=True, text=True, timeout=10).stdout
    assert f"tun2socks-{args.version}" in version and args.revision in version, "Executable version/provenance mismatch"
    help_result = subprocess.run([args.binary, "--help"], check=True, capture_output=True, text=True, timeout=10)
    help_text = help_result.stdout + help_result.stderr
    assert all(flag in help_text for flag in ("--device", "--proxy", "--loglevel")), "Required JNI launcher flags are unavailable"
    # A Unix datagram socket substitutes for the inherited TUN descriptor. No
    # packets are sent; no OS interface, route, DNS setting or VPN profile opens.
    for iteration in range(20):
        descriptor, peer = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)
        # Keep the peer open to prevent an EOF teardown during initialization.
        with descriptor, peer:
            process = subprocess.Popen(
                [args.binary, "--device", f"fd://{descriptor.fileno()}", "--proxy", "socks5://127.0.0.1:9", "--loglevel", "warn"],
                pass_fds=(descriptor.fileno(),), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                time.sleep(0.15)
                assert process.poll() is None, f"Inherited-FD startup failed on cycle {iteration + 1}"
                process.send_signal(signal.SIGTERM)
                stdout, stderr = process.communicate(timeout=5)
                assert process.returncode == 0, f"Clean shutdown failed: {stderr[-1000:]}"
                assert "panic" not in (stdout + stderr).lower(), "Core panicked during FD shutdown"
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate(timeout=5)
    print("tun2socks CLI/version and 20 inherited-FD start/stop cycles passed; no TUN/network traffic was started.")


if __name__ == "__main__":
    main()
