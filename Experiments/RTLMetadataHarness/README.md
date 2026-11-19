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
