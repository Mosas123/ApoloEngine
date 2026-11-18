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
- Remote `http(s)` sources go through AVPlayer directly (no FFmpeg probe, no
  protocol dependency). Local files keep the full FFmpeg probe and route.
- The libavcodec tail is no longer cut: at EOF the clock keeps running until
  the enqueued audio has played, then the finish is published.
- libavcodec positions are track-relative across gapless switches, so UI seek
  and Now Playing stay correct after the first automatic advance.

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

## Audit backlog

Fixed in phase 1 (CI green, 19 tests):

- Tap lifetime: `passRetained` + `release` in `finalize` (no use-after-free).
- Tap state under one lock; planar pointer array reused on the audio thread.
- `loadEpoch`: a superseded probe can no longer overwrite the engine.
- Audio-session failure degrades instead of stranding `.loading`; probe errors
  set `.failed`.
- Stale `media`/`duration`/`elapsed` cleared on track advance and seek.
- `AVQueuePlayer` end detection uses the item that actually ended.
- `timelineEnd` reset on seek; `enqueueNext` restarts a finished host.
- swresample flushed at EOF (no lost tail).
- `avcodec_send_packet` EAGAIN drains and retries instead of dropping packets.
- Seek uses `AVSEEK_FLAG_BACKWARD` + `avformat_flush`.
- Non-audio streams set to `AVDISCARD_ALL`.
- Flat EQ skips zero-gain bands; non-finite gains are ignored.
- Track tail kept at EOF (delayed finish instead of stopping the clock early).
- Track-relative time across gapless (`trackStart` + lock), seek adds the
  offset, `timelineEnd` tracks absolute positions.
- Remote HTTP(S) routed to AVPlayer; probe duration falls back to the audio
  stream when the container has none; `failedToPlayToEndTime` surfaces AVPlayer
  failures.
- Probe results cached (LRU 32, keyed by path + size + mtime, or URL + headers).
- Single open for local files: `OpenedSource` runs `avformat_find_stream_info`
  once and hands the `AVFormatContext` to `AudioDecoder` on the libavcodec
  route; the AVPlayer route closes it after reading the info.
- Refill is one buffer per callback, so control commands interleave with
  decoding instead of waiting for a long burst.
- Seek pre-roll: frames before the requested position are dropped instead of
  playing the previous keyframe's tail.
- EQ changes are click-free: coefficients are rewritten in place and each
  biquad keeps its `z1`/`z2`, so moving a slider does not reset the filter.
- 7-channel PCM: the resampler is forced to `6.1(back)` so `MPEG_6_1_A`
  describes the actual order. 1/2/4/5/6/8 already match the default order
  (cross-checked against AetherEngine); there is a layout test.

Open:

1. **FFmpeg over HTTP** for exotic remote formats (APE/TTA/WavPack over HTTP):
   custom `AVIOContext` over `URLSession`, or enable `network`/`http`/`https` +
   `securetransport` in the fork build (another multi-hour run). Standard
   remote music already plays through AVPlayer.
2. ~~Separate the control queue from the render queue.~~ The refill now
   enqueues one buffer per `requestMediaDataWhenReady` callback, so pause/seek
   queued on the same serial queue run between steps. No second queue needed.
3. Probe tuning (`probesize`/`analyzeduration`).
5. ~~Lookahead limiter and click-free EQ changes.~~ EQ changes are now
   click-free (coefficients rewritten in place, biquad memory and limiter
   envelope kept). A lookahead limiter is deliberately **not** used: it adds
   5 ms of latency and a 5 ms silence at every gapless boundary, because the
   processing chain is per track.
6. AVPlayer: probe queued tracks for ReplayGain; Now Playing artwork and
   `MPNowPlayingInfoPropertyMediaType`.
7. Tests: JOC/`dec3`, ReplayGain parsing, tap lifetime, gapless integration.

Note: `CMSampleTimingInfo.duration = 1/sampleRate` with one timing entry is
**correct** (CoreMedia treats it per-sample; verified against AetherEngine).
Do not "fix" it to the buffer total.

## Decisions

- **No embedded libmpv.** We take mpv's codec/filter ideas into our own FFmpeg
  build and keep the Apple output path; shipping libmpv would mean two FFmpegs
  and lose the native renderer.
- **KSPlayer rejected.** It only adds app UI and video conveniences; its audio
  stack is behind what we have, and its licence (GPL by default, LGPL paid) is
  worse for a closed-source App Store app. UI belongs to the app, not the engine.

## Known constraints

- iOS 18+; Spatial Audio / object audio effectively wants iOS 26.
- Taps only process Float32 buffers; other AVPlayer processing formats play
  without processing instead of failing.
- JOC passthrough relies on the system Atmos decoder; no bundled primer yet.
