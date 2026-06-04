#!/usr/bin/env python3
"""Take one screenshot of a running QEMU VM via its QMP socket.

Usage: qmp_screendump.py <qmp-socket-path> <output-file.png>

Connects to the QMP Unix socket Packer exposes (qmp_enable=true), negotiates
capabilities, and issues `screendump`. Tries PNG (QEMU >= 7.1); falls back to
PPM if this QEMU lacks libpng. No third-party deps -- raw socket + json so it
runs on a bare GitHub runner.
"""
import json
import socket
import sys


def _read_reply(f):
    """Read lines until a command result (skip async events)."""
    while True:
        line = f.readline()
        if not line:
            return None
        msg = json.loads(line)
        if "return" in msg or "error" in msg:
            return msg


def main():
    sock_path, out_path = sys.argv[1], sys.argv[2]
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    s.connect(sock_path)
    f = s.makefile("rw", newline="")

    f.readline()  # QMP greeting banner

    def cmd(obj):
        f.write(json.dumps(obj) + "\r\n")
        f.flush()
        return _read_reply(f)

    cmd({"execute": "qmp_capabilities"})

    # Prefer PNG; fall back to PPM if the format arg is rejected.
    r = cmd({"execute": "screendump",
             "arguments": {"filename": out_path, "format": "png"}})
    if r and "error" in r:
        ppm = out_path.rsplit(".", 1)[0] + ".ppm"
        r = cmd({"execute": "screendump", "arguments": {"filename": ppm}})
        if r and "error" in r:
            print("screendump failed:", r["error"], file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
