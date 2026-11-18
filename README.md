# ApoloEngine

Music and streaming engine for iOS. AVFoundation plays, FFmpeg probes and
covers what AVFoundation cannot.

## Architecture

```
Streaming (URLSession / HTTP headers)
        |
FFmpeg probe (demux only, AetherFFmpegBuild)
        |
  route decision
   ├─ AVPlayer        (aac, alac, mp3, flac, ac3, eac3, opus, ...)
   └─ libavcodec → AVSampleBufferAudioRenderer   [roadmap]
        |
Spatial Audio / Atmos / AirPods
        |
Now Playing · gapless · loudness normalisation   [roadmap]
```

## Requirements

- iOS 18+
- Swift 6.1
- `FFmpegBuild` (Aether-prefixed) 3.15.x

## Install

```swift
.package(url: "https://github.com/Mosas123/ApoloEngine", from: "0.1.0")
```

## Use

```swift
import ApoloEngine

let engine = ApoloEngine()

try await engine.load(
    url: streamURL,
    httpHeaders: ["Authorization": "Bearer ..."],
    metadata: NowPlayingMetadata(title: "Track", artist: "Artist")
)

engine.play()
```

## Status

| Area | State |
| --- | --- |
| FFmpeg probe (container, codecs, Atmos flag) | working |
| AVPlayer audio path | working |
| Now Playing + remote commands | working |
| Spatial Audio session (`setSupportsMultichannelContent`) | working |
| libavcodec → `AVSampleBufferAudioRenderer` | roadmap |
| E-AC-3 JOC (Atmos) passthrough | roadmap |
| Loudness normalisation + limiter | roadmap |
| APAC (AirPlay / HomePod Atmos) | roadmap |
| Gapless | roadmap |

## Licence

TBD. Uses `FFmpegBuild` (FFmpeg), whose LGPL obligations apply.
