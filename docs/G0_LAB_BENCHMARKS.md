# G0 lab benchmarks — ApoloEngine + FFmpeg bridge

**Status:** diagnostic experiment, 23 November 2026. No fixes, no merge, no change to Trop or main. Companion to [ApoloEngine issue #22](https://github.com/Mosas123/ApoloEngine/issues/22).

## Scope: what these tests actually measure

An isolated **iOS Simulator** XCTest run using existing repository-owned `Fixtures/tone.flac`. Each custom timing prints 20 nanosecond observations summarized with **nearest-rank p50/p95**. One additional XCTest performance test reports clock, CPU, and memory metrics for a repeatable block of 20 complete cycles.

| Output phase | Includes | Excludes |
| --- | --- | --- |
| `local-flac-probe-and-close` | FFmpeg file open, demux/probe, stream discovery and close | decoder init, renderer, network |
| `local-flac-open-decode-to-eof-close` | FFmpeg file I/O, libavformat, libavcodec, optional libswresample, ApoloEngine DSP/PCM/CoreMedia buffering and close | network, AVSampleBufferAudioRenderer playback, acoustic signal |
| `local-flac-seek-to-first-pcm` | `AudioDecoder.seek(to:)`, FFmpeg seek/flush/resampler reset and next decoded buffer | opening file, close, actual audible seek latency |
| `testG0LifecycleCPUAndMemory` | XCTest process-level clock/CPU/memory metrics for 20 complete local decode cycles per measurement iteration | isolated libavcodec CPU, peak on-device RSS, battery, thermal |

The benchmark suite is **not** proof of a leak, bit-perfect or sample-exact output, EOF correctness in every file, first audible sample, a specific Apple hardware route, or energy efficiency. An XCTest memory metric is not automatically peak RSS on an iPhone. The 20-cycle benchmark is an exploratory signal, **not** an exhaustive leak detector.

## Running and retrieving evidence

- Pull requests with head branch `diag/g0-lab-*` automatically trigger `.github/workflows/g0-lab-benchmarks.yml`. Other PRs do not run these benchmarks; the regular CI still compiles the tests, but **skips them** because the opt-in variable is absent.
- The workflow invokes `xcodebuild test` with `-only-testing:ApoloEngineTests/G0LabBenchmarks` and `TEST_RUNNER_APOLO_G0_LAB=1` (Xcode forwards `TEST_RUNNER_` variables to XCTest with that prefix removed).
- Artifacts: `g0-lab-output.log` (look for `G0_LAB phase=... min/p50/p95/max unit=nanoseconds`), `g0-lab-environment.txt` (exact commit, SDK/toolchain, fixture hash, simulator name), and complete `g0-lab.xcresult` for XCTest CPU/memory values. Raw artifact retained for **14 days**.
- No external network media, API credentials or user audio are used; the audio fixture is a bundled local test file.

### Rules for interpreting results

1. Warm-up once; collect 20 actual measurements per phase. Compare **the same metric** with the same fixture SHA, runner class, Xcode version, simulator configuration and build flags.
2. Nanosecond timestamps have finer resolution than millisecond logs but are still affected by scheduling, cache warmth, throttling and shared-host noise. A low p50 is not proof of zero CPU.
3. Timed decode is the **entire** ApoloEngine decode/PCM pipeline, not an isolated `libavcodec` hot loop. Likewise HTTP Range/AVIO latency is absent and must be evaluated separately.
4. No fixed CI thresholds or performance pass/fail judgments until there are repeated baselines and statistical comparison. Correctness failures (crashes, no output, unexpected frame-count changes, no EOF) are actionable evidence, not optimization permission.
5. To investigate memory leaks use controlled ownership/instrumentation, allocations and more lifecycle iterations, distinguishing autorelease pools, memory caches, persistent ownership and retained buffers.
6. Results from GitHub-hosted Simulator do **not** establish actual iPhone CPU/RAM/energy, Bluetooth/AirPlay routing or acoustic quality. Those require separately controlled physical QA.

## Still required before G0 closes

This first benchmark covers the **ApoloEngine local FFmpeg decode bridge** only. The ApoloFFmpeg C libraries still require separately isolated fixtures and profiles for `libavcodec`, `libavformat`, `libavutil`, `libswresample`, `libavfilter`, `libswscale` (and shipped `dav1d`, `zimg`, `zvbi` only where relevant). Never claim this experiment benchmarks each library independently.

Additional gates: network AVIO/HTTP and stop cancellation; local/remote Opus, AAC/ALAC, FLAC and error/EOF; sample-exact PTS/seek and gapless; native Apple routes, ICY FFmpeg path, interruption, sleep/background; `ApoloFFmpeg` A1 source/binary and LGPL compliance; device energy/RSS/CPU and diagnostic overhead comparison against stable baseline. Keep the A1/consumer PRs in draft until verified.

**No source engine code or FFmpeg build recipe is changed by this proposal.**
