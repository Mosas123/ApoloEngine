# Roadmap

Living state of ApoloEngine. Update this file when work moves, so context
never depends on a chat.

## Working today

- Live radio (opt-in): HLS/HTTP/ICY routing, bounded M3U/PLS resolution,
  reconnect budget, stall watchdog, stale-callback fences and duplicate-request
  suppression.
- Live metadata: ICY title callback (`liveTitle`); station artwork and richer
  metadata come from the host app's broadcaster APIs.
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
  `setSupportsMultichannelContent(true)`. The card carries album/artist, the
  encoded artwork (cached) and `MediaType = audio`; commands are explicitly
  enabled.
- Audio interruptions and route loss: a call/Siri pauses, resumes only when the
  system asks and the user had not paused; unplugging headphones pauses.
- Queued local tracks are probed at enqueue time, so their ReplayGain and
  duration survive a gapless automatic advance.
- Hot path reuses one `AVPacket` and one `AVFrame`, and swresample writes
  straight into the `CMBlockBuffer`-owned memory (zero-copy PCM).
- `ApoloEngine.diagnostics` exposes route, container, codec, sample rate,
  channels, Atmos flag, duration and state for a debug screen; `ApoloError`
  conforms to `LocalizedError`.
- Demux read errors are no longer mistaken for EOF: `readNextBuffer()` throws
  `readFailed(code:)` and the host publishes `.failed`.
- Real TTA decode test with a bundled generated fixture.
- Remote `http(s)` sources go through AVPlayer directly (no FFmpeg probe, no
  protocol dependency). Local files keep the full FFmpeg probe and route.
- The libavcodec tail is no longer cut: at EOF the clock keeps running until
  the enqueued audio has played, then the finish is published.
- libavcodec positions are track-relative across gapless switches, so UI seek
  and Now Playing stay correct after the first automatic advance.

## Experimental / in flight

### Live radio device hardening

The live path is functional but still opt-in. Remaining work is on-device polish,
not core routing:

- 30–60 minute background runs per protocol (HLS, MP3, AAC, Ogg/Opus, ICY).
- Now Playing and interruption edge cases: lock screen, route changes,
  AirPlay/AirPods, pause/resume after calls and Siri.
- Wi-Fi/cellular switching, redirects, expired URLs and station-side 403s.
- Playlist resolver limits and error surfaces in the host UI.

Native HLS timed-metadata observation is not part of the supported live path.
Do not enable it in production; the host app supplies metadata through ICY or
broadcaster APIs.

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

**Landed.** `Package.swift` now points at
`https://github.com/Mosas123/FFmpegBuild` (`.branch("apolo-union")`), and CI
asserts at runtime that the APE/TTA/WavPack/Tak/MPC decoders, the matching
demuxers, and the EQ/loudness/crossfeed filters are compiled in (21 tests
green).

The first build left absolute install names in the x86_64 simulator slices, so
those binaries were patched in place and ad-hoc re-signed by the fork's
`sign.yml` workflow. The union build is now manual (`workflow_dispatch`) so a
push cannot start a multi-hour job by accident.

Caveats: the macOS build takes hours, can fail on SDK/disk, and each successful
build adds roughly 380 MB to the FFmpegBuild git history.

Known issue in the first successful build: the **x86_64 simulator** slices keep
absolute `/Users/runner/...` install names (the `install_name_tool` pass missed
them); the **arm64** slices are correct. CI forces `ARCHS=arm64`, which is what
devices and Apple Silicon simulators use. Follow-up: rebuild fixing the
per-slice install names (or drop the x86_64 simulator slice).

## Next

1. APAC (AirPlay / HomePod Atmos): iOS 26+, `AVAudioConverter` with the APAC
   format, the `dapa` box, and an fMP4/HLS delivery path. Deferred until the
   FFmpeg union build is in and there is a real Atmos route to test on.
2. Decode tests for the union containers: **TTA and APE done** (generated tone
   fixtures, 6.9 KB and 3.7 KB, decoded through `OpenedSource` + `AudioDecoder`).
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
- Exotic remote containers (ape/tta/wv/tak/mpc/dsf/aiff/wma/mka) go through the
  FFmpeg HTTP AVIO with Range requests; standard remote music stays on AVPlayer.
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

1. ~~FFmpeg over HTTP~~ Done: `HTTPStream`/`HTTPTransport` (custom AVIO over
   `URLSession`) read with 1 MB `Range` windows and fall back to a full body
   when the server ignores `Range`; `read_packet` returns `AVERROR_EOF`. Finite
   files stay on this path; continuous streams use the live route below.
   Covered by an end-to-end test with a mocked `URLProtocol`.
2. ~~Separate the control queue from the render queue.~~ The refill now
   enqueues one buffer per `requestMediaDataWhenReady` callback, so pause/seek
   queued on the same serial queue run between steps. No second queue needed.
3. Probe tuning (`probesize`/`analyzeduration`).
5. ~~Lookahead limiter and click-free EQ changes.~~ EQ changes are now
   click-free (coefficients rewritten in place, biquad memory and limiter
   envelope kept). A lookahead limiter is deliberately **not** used: it adds
   5 ms of latency and a 5 ms silence at every gapless boundary, because the
   processing chain is per track.
6. ~~AVPlayer: probe queued tracks for ReplayGain.~~ Queued local tracks are
   probed when enqueued; the gain and duration travel with `ApoloTrack` and are
   applied on advance (both routes).
7. Tests: JOC/`dec3` and ReplayGain done; tap lifetime and gapless integration
   still manual.
8. ~~Remaining PCM copy.~~ Done: swresample writes straight into the memory
   the `CMBlockBuffer` owns; one sample buffer per decoded frame, drained from
   a `readyBuffers` queue. No scratch/pending copies.

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
- Live radio is opt-in and still being validated on device; it is not a
  replacement for the finite-file player.
- Taps only process Float32 buffers; other AVPlayer processing formats play
  without processing instead of failing.
- JOC passthrough relies on the system Atmos decoder; no bundled primer yet.
