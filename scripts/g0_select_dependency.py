#!/usr/bin/env python3
"""Select the pinned FFmpeg candidate in a disposable CI checkout only.

Never commit the rewritten Package.swift and never update main or consumer PRs.
"""
import pathlib
import sys

PIN = "0760ac161498ced0c63d6057abf52cd3432c5086"
LEGACY_URL = 'url: "https://github.com/Mosas123/FFmpegBuild"'
LEGACY_BRANCH = 'branch: "apolo-union"'
A1_URL = 'url: "https://github.com/Mosas123/ApoloFFmpeg"'
A1_REVISION = f'revision: "{PIN}"'


def main() -> None:
    if len(sys.argv) != 2 or sys.argv[1] not in ("baseline", "a1"):
        raise SystemExit("Usage: g0_select_dependency.py baseline|a1")
    name = sys.argv[1]
    path = pathlib.Path("Package.swift")
    source = path.read_text(encoding="utf-8")
    assert source.count(LEGACY_URL) == 1, "Unexpected dependency origin"
    assert source.count(LEGACY_BRANCH) == 1, "Unexpected dependency branch"
    count = source.count('package: "FFmpegBuild"')
    assert count == 9, f"Unexpected package product count: {count}"
    if name == "baseline":
        print("G0_DEPENDENCY variant=baseline origin=FFmpegBuild ref=apolo-union")
        return

    source = source.replace(LEGACY_URL, A1_URL)
    source = source.replace(LEGACY_BRANCH, A1_REVISION)
    source = source.replace('package: "FFmpegBuild"', 'package: "ApoloFFmpeg"')
    assert source.count(A1_URL) == 1 and source.count(A1_REVISION) == 1
    assert source.count('package: "ApoloFFmpeg"') == count
    path.write_text(source, encoding="utf-8")
    print(f"G0_DEPENDENCY variant=a1 origin=ApoloFFmpeg revision={PIN}")


if __name__ == "__main__":
    main()
