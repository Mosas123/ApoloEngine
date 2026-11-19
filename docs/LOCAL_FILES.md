# Local audio routing — iOS beta v9

## Previous behavior and reported symptom

Thrum's downloaded tracks arrive as local `file://` URLs. ApoloEngine
previously attempted a synchronous/async libavformat probe of **every**
local file, including ordinary `m4a`, `mp3` and `aac`, before selecting
the AVPlayer route. If that probe rejected the container or could not
read the file, the native player was never attempted.

## Change

- Files with native Apple audio extensions `m4a`, `m4b`, `mp3`,
  `aac` and `mp4` now go **directly to AVPlayer**, exactly like known
  native remote audio. Their metadata, equalizer, limiter and Spatial/Atmos
  behavior remain on the existing Apple host.
- Explicit exotic MIME hints override an Apple-looking extension so FLAC,
  Ogg/Opus, WebM and Vorbis still use FFmpeg. Native FLAC routing is **not**
  forced and remains on the existing FFmpeg demux/decode chain.
- Local WAV/AIFF/APE/TTA and unfamiliar formats continue through the
  existing probe and container/codec selector. Local files never go to the
  live radio transport and do not require network access.
- Added pure route checks for local Apple audio, exotic formats, explicit
  MIME and remote URL isolation.

**Validation**: the iOS simulator CI checks routing/build; hardware
acceptance is still required. An asset with a misleading extension or
a damaged file can fail in either decoder. The Thrum beta retains its
MPVKit fallback; this is not a guarantee that every file is playable.

## Manual iPhone acceptance

1. Use Files import in Thrum Downloads, and also try already downloaded
   songs. Test M4A, MP3 and FLAC while airplane mode is enabled.
2. Confirm playback actually starts, the progress advances, and play/pause,
   seek, lock screen, and next in queue work.
3. Kill and restart Thrum, re-open Downloads: MP3/FLAC remain discoverable.
4. Compare Lossless/Atmos on normal streaming music; verify those routes are
   unchanged. Radio LIVE remains independent.
5. If an asset fails, inspect the device's `APOLO_BETA` and
   `TRANSITION` log messages; don't infer success from the metadata card.
