#!/usr/bin/env python3
"""Summarize an .ips crash: exception, far, registers and top frames."""
import json
import sys


def main() -> None:
    path = sys.argv[1]
    with open(path) as handle:
        meta = json.loads(handle.readline())
        body = json.load(handle)
    print("file:", meta.get("app_name"), meta.get("os_version"), meta.get("timestamp"))
    print("incident:", meta.get("incident_id"))
    print("exception:", body.get("exception"))
    thread = body["threads"][body.get("faultingThread", 0)]
    state = thread.get("threadState", {})
    for key in ("far", "pc", "lr", "x1", "x2", "x16", "x25"):
        item = state.get(key)
        if not item:
            continue
        value = item.get("value")
        print(f"{key}: {value:#x}" if isinstance(value, int) else f"{key}: {value}")
    print("frames:")
    images = body.get("usedImages", [])
    for index, frame in enumerate(thread.get("frames", [])[:10]):
        image = images[frame.get("imageIndex", 0)] if frame.get("imageIndex") is not None else {}
        print(f"  {index:>2} {frame.get('symbol', '?')} {frame.get('symbolLocation', '')} [{image.get('name', '?')}]")


if __name__ == "__main__":
    main()
