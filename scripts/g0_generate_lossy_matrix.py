#!/usr/bin/env python3
"""F03A: deterministic AAC/Opus fixtures and host FFmpeg decode references.
Host decoding is a differential reference, NOT an independent codec implementation.
"""
import hashlib
import json
import math
import pathlib
import shutil
import struct
import subprocess
import sys
import tempfile
import wave

CASES = (
    ("aac", "m4a", 44100, 2, 49152, "192k"),
    ("aac", "m4a", 48000, 1, 49152, "96k"),
    ("opus", "opus", 48000, 1, 48000, "64k"),
    ("opus", "opus", 48000, 2, 48000, "128k"),
)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def stem(codec, ext, rate, channels, frames, bitrate):
    return f"f03a_{codec}_{rate}_{channels}_{frames}"


def source_pcm(rate, channels, frames):
    data = bytearray()
    for i in range(frames):
        fade = min(1, i / 1024, (frames - 1 - i) / 1024)
        for c in range(channels):
            value = fade * (0.36 * math.sin(2 * math.pi * (440 + c * 113) * i / rate)
                            + 0.14 * math.sin(2 * math.pi * (3100 + c * 379) * i / rate))
            data.extend(struct.pack("<h", round(value * 32767)))
    return bytes(data)


def run(*args):
    subprocess.run(args, check=True, timeout=60)


def verify(out):
    manifest = json.loads((out / "manifest.json").read_text())
    assert manifest["generator"]["binary_sha256"]
    entries = manifest["files"]
    assert len(entries) == len(CASES)
    expected = set()
    for case, entry in zip(CASES, entries):
        codec, ext, rate, channels, frames, bitrate = case
        base = stem(*case)
        expected.update((base + "." + ext, base + ".f32"))
        assert entry["case"] == list(case)
        assert entry["file"] == base + "." + ext
        assert entry["reference"] == base + ".f32"
        encoded = (out / entry["file"]).read_bytes()
        ref = (out / entry["reference"]).read_bytes()
        assert sha(encoded) == entry["encoded_sha256"] and len(encoded) > 0
        assert sha(ref) == entry["reference_sha256"]
        assert sha(source_pcm(rate, channels, frames)) == entry["source_pcm_sha256"]
        assert len(ref) == entry["reference_frames"] * channels * 4
        assert frames <= entry["reference_frames"] <= frames + 2048
        values = [x[0] for x in struct.iter_unpack("<f", ref)]
        assert values and all(math.isfinite(x) for x in values)
        assert max(abs(x) for x in values) > 0.1
    assert {p.name for p in out.iterdir() if p.is_file()} == expected | {"manifest.json"}
    print("G0_F03A_FIXTURES verified=4 reference=host_ffmpeg")


def generate(out):
    exe = shutil.which("ffmpeg")
    if not exe:
        raise SystemExit("ffmpeg missing")
    exe = str(pathlib.Path(exe).resolve())
    version = subprocess.check_output([exe, "-version"], text=True, timeout=15)
    manifest = {"generator": {"version": version, "binary_sha256": sha(pathlib.Path(exe).read_bytes()),
                              "reference_kind": "host FFmpeg differential, not independent decoder"},
                "files": []}
    out.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as scratch:
        source = pathlib.Path(scratch) / "source.wav"
        for case in CASES:
            codec, ext, rate, channels, frames, bitrate = case
            raw = source_pcm(rate, channels, frames)
            with wave.open(str(source), "wb") as wav:
                wav.setnchannels(channels)
                wav.setsampwidth(2)
                wav.setframerate(rate)
                wav.writeframes(raw)
            base = stem(*case)
            encoded = out / (base + "." + ext)
            ref = out / (base + ".f32")
            encoder = ["-c:a", "aac", "-profile:a", "aac_low"] if codec == "aac" else ["-c:a", "libopus", "-application", "audio", "-frame_duration", "20"]
            run(exe, "-v", "error", "-y", "-i", str(source), *encoder, "-b:a", bitrate,
                "-map_metadata", "-1", str(encoded))
            run(exe, "-v", "error", "-y", "-i", str(encoded), "-map", "0:a:0",
                "-c:a", "pcm_f32le", "-f", "f32le", str(ref))
            data = ref.read_bytes()
            assert len(data) % (channels * 4) == 0
            source_values = [x[0] / 32768 for x in struct.iter_unpack("<h", raw)]
            ref_values = [x[0] for x in struct.iter_unpack("<f", data)]
            n = min(len(source_values), len(ref_values))
            rms = math.sqrt(sum((a-b)**2 for a,b in zip(source_values[:n], ref_values[:n])) / n)
            manifest["files"].append({
                "case": list(case), "file": encoded.name, "reference": ref.name,
                "source_pcm_sha256": sha(raw), "encoded_sha256": sha(encoded.read_bytes()),
                "reference_sha256": sha(data), "reference_frames": len(data) // (channels * 4),
                "source_vs_reference_index_aligned_rms": rms,
            })
    (out / "manifest.json").write_text(json.dumps(manifest, sort_keys=True, indent=2) + "\n")
    verify(out)
    print(json.dumps(manifest, sort_keys=True))


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in ("generate", "verify"):
        raise SystemExit("Usage: g0_generate_lossy_matrix.py generate|verify OUTPUT")
    (generate if sys.argv[1] == "generate" else verify)(pathlib.Path(sys.argv[2]))
