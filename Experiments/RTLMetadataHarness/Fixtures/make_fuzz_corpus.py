#!/usr/bin/env python3
"""Generate controlled RTL ID3 mutations for crash characterization.

Defensive fuzzing only: each variant changes one field of the malformed WXXX
frame/tag. Audio TS bytes are untouched. Serve the output over HTTP and run one
playlist per cold launch in the harness.

Usage:
    python3 make_fuzz_corpus.py --segment /path/original_001.ts --out /path/corpus
"""
import argparse
import os
import shutil



def syncsafe(value: int) -> bytes:
    return bytes([(value >> 21) & 0x7F, (value >> 14) & 0x7F, (value >> 7) & 0x7F, value & 0x7F])


def read_syncsafe(data: bytearray, offset: int) -> int:
    return ((data[offset] & 0x7F) << 21) | ((data[offset + 1] & 0x7F) << 14) | ((data[offset + 2] & 0x7F) << 7) | (data[offset + 3] & 0x7F)


def tag_and_wxxx(data: bytearray):
    tag = data.find(b"ID3")
    if tag < 0 or data[tag:tag + 3] != b"ID3":
        raise SystemExit("No ID3 tag")
    tag_size = read_syncsafe(data, tag + 6)
    tag_end = tag + 10 + tag_size
    p = tag + 10
    while p + 10 <= tag_end:
        frame_id = bytes(data[p:p + 4])
        frame_size = read_syncsafe(data, p + 4)
        if frame_id == b"WXXX":
            return tag, tag_size, tag_end, p, frame_size, p + 10 + frame_size
        if not all(32 <= b < 127 for b in frame_id) or p + 10 + frame_size > tag_end:
            break
        p += 10 + frame_size
    raise SystemExit("No WXXX frame")


def fix_wxxx(data: bytearray) -> bytearray:
    d = bytearray(data)
    _, _, _, p, fs, frame_end = tag_and_wxxx(d)
    body = bytes(d[p + 10:frame_end])
    bad = b"htG\x03\xe8\x11tps"
    idx = body.find(bad)
    if idx >= 0 and frame_end + 4 <= len(d) and bytes(d[frame_end:frame_end + 4]) == b".jpg":
        new_body = body[:idx] + b"https" + body[idx + len(bad):] + b".jpg"
        if len(new_body) == len(body):
            d[p + 10:frame_end] = new_body
            d[frame_end:frame_end + 4] = b"\x00\x00\x00\x00"
    return d


def set_size(d: bytearray, frame_start: int, size: int) -> None:
    d[frame_start + 4:frame_start + 8] = syncsafe(size)


def variants(raw: bytearray):
    tag, tag_size, tag_end, p, fs, frame_end = tag_and_wxxx(raw)
    yield "original", bytearray(raw)
    yield "fixed", fix_wxxx(raw)

    d = bytearray(raw); set_size(d, p, max(0, fs - 4)); yield "wxxx_size_minus4", d
    d = bytearray(raw); set_size(d, p, fs + 4); yield "wxxx_size_plus4", d
    d = bytearray(raw); set_size(d, p, 0x0FFFFFFF); yield "wxxx_size_huge", d
    d = bytearray(raw); set_size(d, p, 0); yield "wxxx_size_zero", d
    d = bytearray(raw); d[tag + 6:tag + 10] = syncsafe(max(0, p - tag - 10)); yield "tag_size_before_wxxx", d
    d = bytearray(raw); d[tag + 6:tag + 10] = syncsafe(600); yield "tag_size_600", d
    d = bytearray(raw); d[p:p + 4] = b"wxxx"; yield "wxxx_id_lower", d
    d = bytearray(raw); d[p:p + 4] = b"XXXX"; yield "wxxx_id_unknown", d
    d = bytearray(raw)
    body = bytes(d[p + 10:frame_end])
    idx = body.find(b"https://")
    if idx >= 0:
        d[p + 10 + idx + 8] = 0
    yield "url_nul", d
    d = bytearray(raw)
    idx = bytes(d[p + 10:frame_end]).find(b"htG\x03\xe8\x11tps")
    if idx >= 0:
        d[p + 10 + idx + 2:p + 10 + idx + 6] = b"\x00\x00\x00\x00"
    yield "stray_zeroed", d


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--segment", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--copies", type=int, default=6)
    args = ap.parse_args()
    raw = bytearray(open(args.segment, "rb").read())
    shutil.rmtree(args.out, ignore_errors=True)
    os.makedirs(args.out)
    for name, data in variants(raw):
        for copy in range(1, args.copies + 1):
            open(os.path.join(args.out, f"{name}_r{copy:02d}.ts"), "wb").write(data)
        lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:6", "#EXT-X-MEDIA-SEQUENCE:1"]
        for copy in range(1, args.copies + 1):
            lines += ["#EXTINF:5.760,", f"{name}_r{copy:02d}.ts"]
        lines.append("#EXT-X-ENDLIST")
        open(os.path.join(args.out, f"{name}.m3u8"), "w").write("\n".join(lines) + "\n")
    print(f"Wrote {len(list(os.listdir(args.out))) } files to {args.out}")


if __name__ == "__main__":
    main()
