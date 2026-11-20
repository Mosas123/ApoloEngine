# ApoloEngine

Music and streaming engine for iOS. AVFoundation plays what it can; FFmpeg
covers the rest and feeds the same Apple renderer, so Spatial Audio and Atmos
stay available on both routes.

## Architecture

```
local source ──► OpenedSource (one FFmpeg open + probe) ──► route
remote source ─► AVPlayer (standard) / FFmpeg over HTTP AVIO (exotic)

route
 ├─ AVPlayer / AVQueuePlayer
 │    └─ MTAudioProcessingTap: EQ, ReplayGain gain, limiter
 └─ libavcodec
      └─ Float32 PCM ──► CMSampleBuffer ──► AVSampleBufferAudioRenderer
                                            (+ AVSampleBufferRenderSynchronizer)

shared
 └─ AVAudioSession (multichannel / Spatial), Now Playing, interruptions

live source ──► HLS/HTTP/ICY route
 ├─ native AVPlayer (HLS and compatible HTTP streams)
 └─ FFmpeg + LiveHTTPStream (ICY, raw HTTP and exotic live containers)
```

FFmpeg's build has no network protocols, so remote FFmpeg sources are read by a
custom `AVIOContext` backed by `URLSession` with 1 MB `Range` windows. Live
streams use the bounded `LiveHTTPStream` ring and the dedicated ICY path instead.

## Features

- **Probe and routing**: container, duration, codecs and ReplayGain tags; the
  probe cache avoids repeat work and local files are opened once.
- **Codec coverage**: the Apolo FFmpeg union adds APE, TTA, WavPack, Tak and
  Musepack on top of the Apple formats.
- **Spatial Audio and Atmos**: `setSupportsMultichannelContent(true)` plus
  E-AC-3 JOC passthrough to `AVSampleBufferAudioRenderer` for AirPods and
  receivers.
- **DSP**: 5-band peaking EQ with preamp, a peak limiter, and ReplayGain /
  BS.1770 loudness (tags in the container or `LoudnessAnalyzer` offline).
  EQ changes rewrite coefficients in place, so they do not click.
- **Gapless**: AVQueuePlayer with one tap per item on the Apple route; the
  libavcodec route opens the next source on the running synchronizer with a PTS
  offset. `PlayQueue` handles skip/previous.
- **Live radio**: HLS/HTTP/ICY routing, bounded M3U/PLS playlist resolution,
  reconnect budgets, stale-callback fences, duplicate-request suppression and a
  stall watchdog.
- **System integration**: Now Playing with artwork and `MediaType = audio`,
  remote commands, interruptions and headphone unplug.
- **Swift 6** throughout, with simulator and live-radio regression checks.

## Live radio

Use the radio entry points instead of `load(url:)` for continuous streams. The
engine resolves bounded M3U/PLS playlists, chooses HLS versus ICY/HTTP, applies
the reconnect policy and exposes station metadata through the existing Now
Playing callbacks.

Live titles and artwork are supplied by the host app through ICY or broadcaster
APIs.

## Requirements

- iOS 18+ (Spatial and object audio effectively want iOS 26)
- Swift 6.1
- [`Mosas123/FFmpegBuild`](https://github.com/Mosas123/FFmpegBuild), branch
  `apolo-union`

## Install

```swift
.package(url: "https://github.com/Mosas123/ApoloEngine", from: "0.1.6")
```

## Use

```swift
import ApoloEngine

// Host apps that already own the remote commands and the audio session:
let engine = ApoloEngine(
    managesSystemMediaControls: false,
    managesAudioSession: false
)

try await engine.load(
    url: trackURL,
    httpHeaders: ["Authorization": "Bearer ..."],
    metadata: NowPlayingMetadata(
        title: "Track",
        artist: "Artist",
        album: "Album",
        artworkData: imageData
    )
)

engine.equalizer = EqualizerSettings(bandsDB: [4, 0, -1, 0, 3])
engine.limiterEnabled = true
engine.trackGainDB = -2   // on top of any ReplayGain tag

// Prepares a gap-free transition when this track ends.
await engine.enqueueNext(
    ApoloTrack(
        url: nextURL,
        metadata: NowPlayingMetadata(title: "Next", artist: "Artist")
    )
)
```

`skipToNext()` / `skipToPrevious()` reload through the normal route decision,
so a codec change between tracks is handled. `LoudnessAnalyzer.gain(toTarget:)`
computes a per-track gain when the container has no ReplayGain tag.

## Routes

| Source | Route | Notes |
| --- | --- | --- |
| Local, Apple codec | AVPlayer | Probe once, then hand the file to AVFoundation. FLAC uses libavcodec |
| Local, exotic codec | libavcodec → `AVSampleBufferAudioRenderer` | APE/TTA/WavPack/Tak/MPC/DSD-ish |
| Remote, standard | AVPlayer | AAC/ALAC/MP3/FLAC/E-AC-3, native Spatial/Atmos |
| Remote, exotic | FFmpeg HTTP AVIO | `ape/tta/wv/tak/mpc/dsf/aiff/wma/mka`, `webm/ogg/opus` and **FLAC** (extension, URL `mime` or resolver hint); finite files |
| Remote live | AVPlayer or FFmpeg `LiveHTTPStream` | HLS, HTTP and ICY; bounded M3U/PLS resolution, reconnect and watchdog |

Finite remote music uses AVPlayer for standard codecs and FFmpeg HTTP AVIO for
exotic codecs. Continuous streams use the live route, never the finite-file
`Range` path.

## Status

| Area | State |
| --- | --- |
| FFmpeg probe + probe cache + single open | working |
| AVPlayer route with tap (EQ, gain, limiter) | working |
| libavcodec → `AVSampleBufferAudioRenderer` | working |
| E-AC-3 JOC (Atmos) passthrough | working |
| ReplayGain + BS.1770 loudness | working |
| Gapless, queue, skip/previous | working |
| Now Playing artwork, interruptions, route loss | working |
| HTTP AVIO for exotic remote sources | working |
| Live HLS/HTTP/ICY, playlists and reconnect | working |
| Live-radio watchdog and stale-callback fences | working |
| APAC (AirPlay / HomePod Atmos) | not implemented |
| Video / subtitles | out of scope |

## Testing

```bash
xcodebuild test \
  -scheme ApoloEngine \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO
```

## Caveats

- The FFmpeg union is a custom build (manual workflow) and each rebuild adds
  roughly 380 MB to that repository's history.
- The x86_64 simulator slices of that build were patched and ad-hoc signed;
  arm64 (device and Apple Silicon simulator) is the production path.
- JOC passthrough depends on the system Atmos decoder; there is no bundled
  primer.
- FLAC always uses libavcodec now, local and remote. Opaque remote URLs need
  the resolver MIME hint (`sourceMIMEType`).
- The AVPlayer tap is attached as soon as the audio track loads, so a remote
  asset can play a few unprocessed frames before the tap is in place.
- Live radio is intentionally opt-in in the host app; finite-file behavior is
  unchanged when the live entry points are not used.

## Licence

TBD. Uses FFmpeg (LGPL), shipped as dynamic frameworks.
