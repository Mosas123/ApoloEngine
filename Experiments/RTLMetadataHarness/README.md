# RTL France HLS — isolated AVFoundation crash harness

**EXPERIMENTAL, CRASH RISK. This is NOT part of ApoloEngine's Package.swift, Thrum, or a normal music build.**

## Origin

On Nov 19, 2026, Trop/Thrum 0.14.0 build 362 on iOS 27.0.1 crashed while playing RTL France HLS. The main-thread stack was:

    objc_release
    __NSFrozenDictionaryM dealloc
    AVPlayerItemMetadataOutput._pushTimedMetadataGroups
    AVPerformDelegateCallback...

The failing radio had been loaded **twice 1.231 seconds apart**. The safe Thrum PR #21 fixed unnecessary duplicate starts, with 13/13 repeated selections suppressed on device, and >2 minutes of stable RTL native HLS with metadata output OFF. None of this proves the crash is fixed with metadata ON.

Tracking: https://github.com/Mosas123/ApoloEngine/issues/13

## Goal

Reproduce the private AVFoundation failure in a **standalone iOS app**, independently of Thrum, ApoloEngine, FFmpeg, MPVKit, audio DSP, player queue logic and media integrations.

Choose one variable at a time:

- **OFF / AVQueuePlayer / One load**: baseline; metadata output is not constructed
- **OFF / AVQueuePlayer / Reload at 1.231 seconds**: isolate fast lifecycle changes without an output
- **Title IDs / main queue**: matches two identifiers and delegate queue of unsafe experimental ApoloEngine PR #12
- **Title IDs / serial queue**: same observer and source; isolate delegate queue behavior
- **All IDs / main queue**: broader, potentially higher-risk observer control
- AVQueuePlayer vs AVPlayer
- One load vs double load with 1.231 s spacing

The first unsafe observer mode must only be run after the user explicitly acknowledges the crash risk.

## Malformed ID3 in the live RTL stream (Nov 19, 2026)

Byte inspection of 11 consecutive RTL TS segments found the same **malformed
ID3v2.4 tag** in every one:

- `WXXX` frame size 138, but its URL is corrupted: `ht` + four stray bytes
  (`47 03 e8 11`) + `tps://.../graf`.
- The final `.jpg` sits **outside** the frame.
- The next four bytes (`.jpg`) are then read as a frame id with a bogus size
  of 183,905,368, overrunning the 422-byte tag.
- Valid frames before it: `TIT2`, `TPE1`, `TRSN`, `TRSO`, `WORS`.

This is metadata corruption from the broadcaster/encoder path, not Thrum or
Apolo. It is a strong candidate for the AVFCore trigger; the isolated app is
the only place to prove it.

## Fixture A/B (same audio, different ID3)

`Fixtures/` contains three **single-segment** playlists; they stop after ~5.7 s.
For a >2 minute A/B use the generator with the downloaded TS segments:

    python3 Experiments/RTLMetadataHarness/Fixtures/make_long_fixtures.py \
      --segments /path/to/ts --out /path/to/long --count 30

and serve the output directory. The three variants are:

| Playlist | Metadata |
|---|---|
| `stripped.m3u8` | ID3 tag zeroed (no metadata) |
| `fixed.m3u8` | `WXXX` rebuilt as a valid URL, padding zeroed |
| `original.m3u8` | tag exactly as received (malformed `WXXX`) |

Serve them from **any LAN host** reachable by the iPhone — a Mac is not
required. From the Android phone that runs OpenCode, either run the helper:

    python3 Experiments/RTLMetadataHarness/Fixtures/serve_fixtures.py

or plain Python from the fixtures folder:

    cd Experiments/RTLMetadataHarness/Fixtures
    python3 -m http.server 8765 --bind 0.0.0.0

The helper prints the LAN IP. Keep the phone awake and on the same Wi-Fi as
the iPhone. The override URL is saved when you press Start, so it survives the
next cold launch. Verify the log says `STREAM_SOURCE userOverride=true`; if it
says `radioBrowserUUID`, the override was empty and you are testing live RTL.
Run **one item per cold launch** with metadata output ON:

1. `http://<lan-ip>:8765/stripped.m3u8`
2. `http://<lan-ip>:8765/fixed.m3u8`
3. `http://<lan-ip>:8765/original.m3u8`

Do not re-run `original` in the same process after a crash. Capture one `.ips`
per run. Interpret:

- stripped OK + fixed OK + original crash → malformed `WXXX` is the trigger.
- stripped OK + fixed crash → look at `PRIV`/timed groups/iOS, not the URL.
- stripped crash → the output itself is unsafe regardless of payload.

The harness bundle allows local HTTP for this fixture test only. A successful
fixture run does not enable metadata in ApoloEngine or Thrum.

## Procedure

1. Install as a **separate app** and start with metadata **OFF**, AVQueuePlayer, One load. Play RTL for 180 seconds, export event log.
2. With metadata OFF, select Reload once after 1.231 s. Verify two item generations and no crash.
3. Only when ready for a possible crash in this isolated app, select Title IDs / main queue / One load. Re-run the same source and export the event log.
4. Select Title IDs / main queue / Reload once after 1.231 s. Compare outcomes with single load.
5. If needed, change one variable only: serial delegate queue, AVPlayer, or broad IDs. Collect iOS .ips separately if a crash occurs. Stop at first repeatable failure.

The independent app uses RTL's public Radio Browser station UUID 042d3140-227c-4fac-9387-4903b692d5f2. It looks up a fresh stream URL using the documented API at runtime:

https://de1.api.radio-browser.info/json/stations/byuuid/042d3140-227c-4fac-9387-4903b692d5f2

The public URL can change. Use the optional URL override for an exact authorized HLS URL, if available. **Never publish signed tokens, user account data or private URLs.** The log records only a coarse m3u8 URL *hint*, not the full URL. Verify the actual transport before asserting HLS causality.

## Diagnostics

- Open the app and export the persistent log via ShareLink.
- Console entries are prefixed RTL_HLS_REPRO.
- The persistent event log records item creation, output installation, delegate group counts, detach, player state and run generation.
- The log survives an app crash, but it cannot directly capture AVFCore's internal ownership changes.
- Playback automatically stops after 180 seconds. No test continues after the app exits.
- Preserve any new .ips report and compare its symbolicated stack to the previous one.

## Build

On macOS with Xcode and XcodeGen installed, from this directory:

    xcodegen generate --spec project.yml
    xcodebuild -project RTLMetadataHarness.xcodeproj -scheme RTLMetadataHarness \
      -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
      CODE_SIGNING_ALLOWED=NO build

GitHub Actions workflow: RTL HLS Metadata Isolated iPhone Harness.
The artifact is RTLMetadataHarness-unsigned.ipa. **An unsigned IPA needs valid signing before a stock iPhone can install it.** This bundle is com.cl0udly.RTLMetadataHarness, never com.cl0udly.Thrum.

## Boundaries

- Changing to this harness does NOT enable timed metadata in ApoloEngine.
- A successful 3-minute playback with metadata OFF is not evidence that the output is safe.
- A native Apple stack failure does not itself prove a framework defect vs earlier corruption. A minimal reproducer, .ips and sysdiagnose make any Apple Feedback Assistant submission stronger.
- No normal audio paths are edited or merged by this PR.
