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

1. Gapless playback.
2. APAC encode for AirPlay / HomePod Atmos.
3. Decode tests that exercise the FFmpeg union containers (APE, TTA, WavPack).
4. Optional: analyse a downloaded track with `LoudnessAnalyzer` and feed the
   result into `trackGainDB` when there is no ReplayGain tag.

## Known constraints

- iOS 18+; Spatial Audio / object audio effectively wants iOS 26.
- Taps only process Float32 buffers; other AVPlayer processing formats play
  without processing instead of failing.
- JOC passthrough relies on the system Atmos decoder; no bundled primer yet.
