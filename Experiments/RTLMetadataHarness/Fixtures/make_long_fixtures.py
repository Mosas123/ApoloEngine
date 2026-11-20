#!/usr/bin/env python3
"""Build >2 minute original/fixed/stripped RTL playlists from TS segments.

Usage:
    python3 make_long_fixtures.py --segments /path/to/ts --out /path/out [--count 30]

The input directory must contain RTL `.ts` segments (any names, sorted naturally).
Audio bytes are untouched; only the in-band ID3 tag differs per variant.
"""
import argparse
import os
import shutil


def fix_tag(data: bytearray) -> bytearray:
    d = bytearray(data)
    o = d.find(b"ID3")
    if o < 0 or d[o:o + 3] != b"ID3":
        return d
    size = ((d[o + 6] & 0x7F) << 21) | ((d[o + 7] & 0x7F) << 14) | ((d[o + 8] & 0x7F) << 7) | (d[o + 9] & 0x7F)
    end = o + 10 + size
    p = o + 10
    while p + 10 <= end:
        fid = bytes(d[p:p + 4])
        fs = ((d[p + 4] & 0x7F) << 21) | ((d[p + 5] & 0x7F) << 14) | ((d[p + 6] & 0x7F) << 7) | (d[p + 7] & 0x7F)
        if fid == b"WXXX":
            frame_end = p + 10 + fs
            body = bytes(d[p + 10:frame_end])
            bad = b"htG\x03\xe8\x11tps"
            idx = body.find(bad)
            if idx >= 0 and frame_end + 4 <= len(d) and bytes(d[frame_end:frame_end + 4]) == b".jpg":
                new_body = body[:idx] + b"https" + body[idx + len(bad):] + b".jpg"
                if len(new_body) == len(body):
                    d[p + 10:frame_end] = new_body
                    d[frame_end:frame_end + 4] = b"\x00\x00\x00\x00"
            break
        if not all(32 <= b < 127 for b in fid) or p + 10 + fs > end:
            break
        p += 10 + fs
    return d


def strip_tag(data: bytearray) -> bytearray:
    d = bytearray(data)
    o = d.find(b"ID3")
    if o < 0 or d[o:o + 3] != b"ID3":
        return d
    size = ((d[o + 6] & 0x7F) << 21) | ((d[o + 7] & 0x7F) << 14) | ((d[o + 8] & 0x7F) << 7) | (d[o + 9] & 0x7F)
    for i in range(o, o + 10 + size):
        d[i] = 0
    return d


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--segments", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--count", type=int, default=30)
    args = parser.parse_args()

    files = sorted(
        (os.path.join(args.segments, name) for name in os.listdir(args.segments) if name.endswith(".ts")),
        key=lambda path: [int(part) if part.isdigit() else part for part in os.path.basename(path).replace("-", "_").split("_")],
    )[: args.count]
    if not files:
        raise SystemExit("No .ts segments found")
    os.makedirs(args.out, exist_ok=True)
    for i, path in enumerate(files, 1):
        raw = bytearray(open(path, "rb").read())
        open(os.path.join(args.out, f"original_{i:03d}.ts"), "wb").write(raw)
        open(os.path.join(args.out, f"fixed_{i:03d}.ts"), "wb").write(fix_tag(raw))
        open(os.path.join(args.out, f"stripped_{i:03d}.ts"), "wb").write(strip_tag(raw))

    for variant in ("original", "fixed", "stripped"):
        lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:6", "#EXT-X-MEDIA-SEQUENCE:1"]
        for i in range(1, len(files) + 1):
            lines += ["#EXTINF:5.760,", f"{variant}_{i:03d}.ts"]
        lines.append("#EXT-X-ENDLIST")
        open(os.path.join(args.out, f"{variant}.m3u8"), "w").write("\n".join(lines) + "\n")
    print(f"Wrote {len(files)} segments × 3 variants to {args.out}")


if __name__ == "__main__":
    main()
