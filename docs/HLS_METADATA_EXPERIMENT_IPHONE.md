# Experimental HLS timed-metadata A/B — iPhone only

> **Not production-ready.** The earlier iOS 27.0.1 radio crash entered AVFCore private `AVPlayerItemMetadataOutput._pushTimedMetadataGroups`. The exact cause remains unconfirmed. This experiment can still crash.

## Isolation

- Based on ApoloEngine PR #11, preserving radio safety fixes and native local routing.
- Unlike stable beta, **only this experimental branch** sets `AVPlayerHost.nativeHLSTimedMetadataEnabled = true`.
- Collector installed only for **explicit live HLS** (URL ending `.m3u8` or recognized HLS MIME), never HTTP MP3/AAC, on-demand music, FFmpeg/ICY or Atmos.
- Pass `AVMetadataIdentifier.id3MetadataTitleDescription` and `AVMetadataIdentifier.commonIdentifierTitle` strings, not `identifiers: nil` (all metadata).
- Logs `APOLO_HLS_META attach/titleAccepted/detach` with generation only; no raw signed URL, request headers or metadata values.
- Parser, host generation fencing and teardown logic otherwise unchanged to limit experiment variables.

## Device test checklist

1. Start with stable beta to verify audio works for the suspect HLS station, confirm no crash.
2. Install *experimental* Thrum IPA and switch **ApoloEngine Beta (Live Radio)** ON.
3. Start **the same HLS station**; confirm audio, current song title where the station broadcasts timed ID3.
4. Leave playing 2 minutes; then switch repeatedly between HLS stations, pause/resume, background/foreground, lock/unlock and reconnect AirPods.
5. Record iOS version, station identity (not signed token), approximate failure time and crash `.ips` if EXC_BAD_ACCESS occurs.
6. Long session (>30 min) memory check only after no short-run crash.

**Stop testing if EXC_BAD_ACCESS returns.** Return to the earlier working IPA immediately. Do not use this experimental pin in main or release. Passing unit tests/CI is not proof of device safety.

## Decision gate

If crash reproduces: restore disabled collector and investigate a minimal symbolicated AVFCore reproduction or separate sidecar ID3 metadata path. If stable across repeat device tests, narrow further before considering production opt-in; `AVPlayerItemMetadataCollector` handles HLS EXT-X-DATERANGE rather than being a drop-in substitute for in-band ID3.
