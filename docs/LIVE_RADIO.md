# Live radio support — staged implementation

The engine is being extended to support broadcasts **without compromising on-demand music**. Source lifetime is **explicit**, never inferred from a missing or zero duration.

## Phase 1 — native live playback (this branch)

```swift
try await engine.loadLive(
    url: URL(string: "https://radio.example/live.m3u8")!,
    metadata: NowPlayingMetadata(title: "Example FM", artist: "Live")
)
// Equivalent: engine.load(..., streamMode: .live)
```

- Native `AVQueuePlayer` route for HLS and Apple-compatible direct HTTP MP3/AAC audio.
- The live path skips the finite-asset audio-track preload, does not seek, does not gaplessly enqueue another song, and reports duration as 0.
- Unexpected end-of-stream is a failure, not an end-of-song queue advance.
- Existing `load(...)` is `.onDemand` by default, retaining its current AVPlayer/FFmpeg routes, including Dolby passthrough.
- Native live mode intentionally does not attach `MTAudioProcessingTap` until tests demonstrate that it is safe for indefinite and HLS sources.
- At this phase, Ogg/Opus direct audio and station playlist resolution were not available; later phases below extend these capabilities. `.xspf/.asx` and non-HTTP schemes remain unsupported.

**Not shipped to the Thrum radio UI yet.** Thrum continues to use MPVKit for all live stations during this stage. Source URLs may redirect; the native playback result must be verified on real stations.

## Phase 2 — independent continuous HTTP transport (in development)

This branch introduces `LiveHTTPStream` + `LiveHTTPTransport` for direct Icecast/Shoutcast and other endless formats, separate from file `HTTPStream`:

- `URLSessionDataDelegate` consumes chunks without downloading an infinite response as one `Data` object
- Fixed-capacity (512 KiB) ring buffer, high-/low-water task suspension and explicit overflow failure
- Stateful `icy-metaint` parser strips metadata from audio and publishes track titles via `ApoloEngine.liveTitle` for FFmpeg-routed stations
- Nonseekable FFmpeg AVIO for direct Ogg/Opus/FLAC live streams
- No playlist `.m3u/.pls` resolution yet; live response ending is a failure, not song EOF

Remaining acceptance work and hardening:

- Validate real Icecast/Shoutcast and Ogg/Opus stations on device, including playback, cancellation and memory usage
- Validate reconnect/backoff against real device network interruptions and statuses outside the known terminal set
- Add `.m3u/.pls` playlist resolution, legacy ICY response handling and native timed metadata for HLS
- Stress-test cancellation while a decoder is blocked in FFmpeg opening/probing as well as active playback

Do **not** retrofit the existing seekable `HTTPStream` class with an infinite-radio code path.

## Phase 2B — lifecycle and bounded reconnection (this branch)

- `LiveStreamCancellation` closes the network reader immediately from the main-actor stop/switch path, even when FFmpeg's decoder queue is blocked in a synchronous read or source probe.
- Live playback uses fresh demuxers on reconnection (never splice a fresh Ogg/Opus response into old compressed packets).
- `LiveRetryPolicy` schedules at most three retries after failure (1, 2, and 4 seconds); the attempt budget only resets after at least 60 seconds of confirmed playback, or explicit station selection.
- HTTP 401/403/404/410 responses stop automatic FFmpeg radio retries; no signed station URLs are logged.
- Pausing, stopping, changing stations, or losing the audio route cancels pending retry timers.
- FFmpeg radio publishes playing only after the first decoded audio buffer; unexpected EOF does not advance the song queue.
- Unit coverage includes cancellation of a blocked read, late registration after cancel, terminal HTTP statuses and bounded retry schedule.

**Still pending:** verified on-device reconnects for actual ICY/Ogg/Opus stations, transient disconnections during demux probe, station playlist `.m3u/.pls` resolution, HLS timed metadata, and measured memory/energy over long sessions. This branch is not enabled in Thrum radio.

## Phase 2C — M3U/PLS station playlist resolution (draft v4)

Explicit `loadLive(...)` requests can now resolve HTTP(S) station playlists
(`.m3u` / `.pls`, plus recognized MIME hints) before invoking the existing
native or FFmpeg audio route. The original playlist remains in the queue, so
bounded reconnects can re-resolve short-lived station destinations.

- Streams playlist contents as bytes with a **64 KiB limit per file**, 8-second
  request and 12-second resource timeouts; up to 3 nested playlist files.
- M3U supports comments, EXTINF, and relative links; PLS reads numbered FileN
  entries in numeric order. The first valid HTTP(S) station entry is used.
- HLS `.m3u8` remains on its dedicated AVFoundation route; HLS segment
  playlists are not interpreted as station lists.
- Rejects file/FTP schemes, URLs with userinfo, malformed manifests and
  unexpected HTML/JSON responses. Playlist redirects stay on the same origin.
- For station entries on another origin, **strip all caller-provided request
  headers** before opening audio. Playlist MIME is never passed as audio MIME.
- Existing on-demand music, Dolby, finite-file HTTP transport and Thrum radio
  routing are unchanged.

**Still not established:** live-device reliability, failover to second playlist
entry if the first station is down, redirecting station playlists across origins,
legacy `ICY 200 OK` HTTP behavior, native HLS timed metadata, and identifying
opaque Ogg/Opus endpoint MIME types. CI parser tests are not live station tests.
Keep the PR in draft until simulator CI and iPhone validation pass.

## Phase 3 — integration and acceptance

After the engine's transport APIs and on-device validations are ready, make live radio an opt-in route in Thrum, retaining an MPVKit fallback until confidence is high. Acceptance tests:

- Verified live HLS, MP3, AAC/AAC+, Ogg/Opus and ICY radio stations
- 30–60 minute background playback for each protocol; peak buffer/memory stays bounded
- Wi-Fi/cellular switching; dropouts, redirects, invalid content types and 403 rejection
- Lock-screen controls, route change, AirPlay/AirPods and pause/resume
- ICY title/artist changes; no signed URLs or station credentials in diagnostics
- No regressions to on-demand AAC, WebM/Opus, FLAC Lossless or Atmos passthrough

**Current CI tests cover source classification and model behavior, not real long-running station playback.** A native iOS test remains mandatory before claiming production radio support.
