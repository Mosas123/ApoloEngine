# Roadmap

Living state of ApoloEngine. Update this file when work moves, so context
never depends on a chat.

## Working today

- FFmpeg probe: container, duration, audio codecs, E-AC-3 JOC flag.
- AVPlayer audio path (Apple-playable codecs).
- libavcodec -> `AVSampleBufferAudioRenderer` path.
- E-AC-3 JOC (Atmos) passthrough: `dec3` built through the mp4 muxer, JOC flag
  read out of it, packets handed to the renderer compressed.
- 5-band EQ + preamp + peak limiter on the libavcodec path.
- Now Playing + remote commands, `AVAudioSession` with
  `setSupportsMultichannelContent(true)`.

## In flight

### FFmpeg union build

Goal: one FFmpeg that carries the mpv codecs/filters AetherEngine's build
lacks, while keeping the Apple output path.

- Repo: `Mosas123/FFmpegBuild`, branch `apolo-union`.
- `build.sh` additions:
  - muxer: `mp4` (needed for the `dec3` extraction).
  - filters: `equalizer`, `superequalizer`, `firequalizer`, `bass`, `treble`,
    `loudnorm`, `dynaudnorm`, `crossfeed`, `highpass`, `lowpass`.
  - demuxers: `ape`, `tta`, `wv`, `aiff`, `tak`, `mpc`, `mpc8`.
  - decoders: `ape`, `tta`, `wavpack`, `tak`, `mpc7`, `mpc8`.
- Workflow `.github/workflows/build.yml` runs `./build.sh` on `macos-26` and
  commits the rebuilt `Sources/*.xcframework` back to `apolo-union`
  (commit message `build: xcframeworks ...` is skipped by the job guard).
- First run: https://github.com/Mosas123/FFmpegBuild/actions/runs/44393146128

**When the build lands**, do exactly this in ApoloEngine:

1. `Package.swift`: change the FFmpegBuild dependency to
   `https://github.com/Mosas123/FFmpegBuild`, `.branch("apolo-union")`.
2. `swift package update` / let CI resolve it.
3. Run CI. `testMP4MuxerIsAvailable` must stay green.
4. Add a decode test for a generated APE or TTA file through `AudioDecoder`.

Caveats: the macOS build takes hours, can fail on SDK/disk, and each successful
build adds roughly 380 MB to the FFmpegBuild git history.

## Next

1. ReplayGain / EBU R128 normalisation (per-track gain + the existing limiter).
2. EQ on the AVPlayer route via `MTAudioProcessingTap` (today it only applies on
   the libavcodec route).
3. Gapless playback.
4. APAC encode for AirPlay / HomePod Atmos.
5. Decode tests that exercise the FFmpeg union containers (APE, TTA, WavPack).

## Known constraints

- iOS 18+; Spatial Audio / object audio effectively wants iOS 26.
- The EQ is applied only where ApoloEngine owns the PCM (libavcodec route).
- JOC passthrough relies on the system Atmos decoder; no bundled primer yet.
