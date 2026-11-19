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
- Unsupported formats (for example Ogg/Opus direct radio), non-HTTP schemes, and `.pls/.m3u/.xspf/.asx` station playlists fail explicitly rather than guessing.

**Not shipped to the Thrum radio UI yet.** Thrum continues to use MPVKit for all live stations during this stage. Source URLs may redirect; the native playback result must be verified on real stations.

## Phase 2 — independent continuous HTTP transport (in development)

This branch introduces `LiveHTTPStream` + `LiveHTTPTransport` for direct Icecast/Shoutcast and other endless formats, separate from file `HTTPStream`:

- `URLSessionDataDelegate` consumes chunks without downloading an infinite response as one `Data` object
- Fixed-capacity (512 KiB) ring buffer, high-/low-water task suspension and explicit overflow failure
- Stateful `icy-metaint` parser strips metadata from audio and publishes track titles via `ApoloEngine.liveTitle` for FFmpeg-routed stations
- Nonseekable FFmpeg AVIO for direct Ogg/Opus/FLAC live streams
- No playlist `.m3u/.pls` resolution or automatic reconnection yet; live response ending is a failure, not song EOF

Remaining acceptance work and hardening:

- Validate real Icecast/Shoutcast and Ogg/Opus stations on device, including playback, cancellation and memory usage
- Add bounded reconnection/backoff for transient failures; maintain terminal status on 401/403/404
- Add `.m3u/.pls` playlist resolution, legacy ICY response handling and native timed metadata for HLS
- Avoid long decode-queue stops when a network read is blocked; add explicit interruption/cancellation support

Do **not** retrofit the existing seekable `HTTPStream` class with an infinite-radio code path.

## Phase 3 — integration and acceptance

After the engine's transport APIs and on-device validations are ready, make live radio an opt-in route in Thrum, retaining an MPVKit fallback until confidence is high. Acceptance tests:

- Verified live HLS, MP3, AAC/AAC+, Ogg/Opus and ICY radio stations
- 30–60 minute background playback for each protocol; peak buffer/memory stays bounded
- Wi-Fi/cellular switching; dropouts, redirects, invalid content types and 403 rejection
- Lock-screen controls, route change, AirPlay/AirPods and pause/resume
- ICY title/artist changes; no signed URLs or station credentials in diagnostics
- No regressions to on-demand AAC, WebM/Opus, FLAC Lossless or Atmos passthrough

**Current CI tests cover source classification and model behavior, not real long-running station playback.** A native iOS test remains mandatory before claiming production radio support.
