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
- ReplayGain: `MediaProbe` reads `replaygain_track_gain` from the container and
  the libavcodec path applies it through the limiter. `LoudnessAnalyzer` computes
  BS.1770 / EBU R128 integrated loudness (K-weighting, 400 ms blocks, gating) for
  offline per-track gain.
- EQ, ReplayGain gain and limiter on the **AVPlayer route** too, through
  `MTAudioProcessingTap` (`AudioTapProcessor`): planar/interleaved float, chain
  swapped under a lock.
- Gapless: `AVQueuePlayer` with one tap per item on the AVPlayer route; the
  libavcodec route opens the next source on the running synchronizer and offsets
  its PTS by the previous track's end. `ApoloEngine.enqueueNext(_:)` feeds it.
- Manual `skipToNext()` / `skipToPrevious()` over a pure `PlayQueue` (unit
  tested). Skips reload through the normal route decision, so a codec change
  between tracks is handled; a skip may re-introduce a small gap.
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
- First run failed with `autoreconf: command not found` (exit 127). The workflow
  now installs `autoconf automake libtool pkg-config meson ninja nasm` first.
- Runs: https://github.com/Mosas123/FFmpegBuild/actions/workflows/build.yml

**When the build lands**, do exactly this in ApoloEngine:

1. `Package.swift`: change the FFmpegBuild dependency to
   `https://github.com/Mosas123/FFmpegBuild`, `.branch("apolo-union")`.
2. `swift package update` / let CI resolve it.
3. Run CI. `testMP4MuxerIsAvailable` must stay green.
4. Add a decode test for a generated APE or TTA file through `AudioDecoder`.

Caveats: the macOS build takes hours, can fail on SDK/disk, and each successful
build adds roughly 380 MB to the FFmpegBuild git history.

## Next

1. APAC (AirPlay / HomePod Atmos): iOS 26+, `AVAudioConverter` with the APAC
   format, the `dapa` box, and an fMP4/HLS delivery path. Deferred until the
   FFmpeg union build is in and there is a real Atmos route to test on.
2. Decode tests that exercise the FFmpeg union containers (APE, TTA, WavPack).
3. Optional: analyse a downloaded track with `LoudnessAnalyzer` and feed the
   result into `trackGainDB` when there is no ReplayGain tag.

## Known constraints

- iOS 18+; Spatial Audio / object audio effectively wants iOS 26.
- Taps only process Float32 buffers; other AVPlayer processing formats play
  without processing instead of failing.
- JOC passthrough relies on the system Atmos decoder; no bundled primer yet.
