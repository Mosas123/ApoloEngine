# G0: Observability and measurement contract (diagnostic-only candidate)

Status: **DRAFT, never merge without CI + review + optional iPhone QA**.

## Why this exists

This change prepares the missing quantitative gate of the six-stage audit. It
**does not fix** EOF, HTTP cancellation, seek, routing, buffering, sample
precision, AudioSession, or any FFmpeg codec. No change to Trop, its dependency
pin, or the current ApoloFFmpeg A1 candidate. The code uses the existing
`ApoloEngine.setDiagnosticHandler` mechanism; Trop already writes callbacks
as `APOLO_DIAG ...` into its rotating, exportable process log.

## The trace and metrics

All new lines are allowlisted, numeric or fixed literals, and contain **no
URLs, cookies, headers, user identifiers, artwork, titles or song IDs**.

```text
APOLO_DIAG lifecycle v=1 action=load epoch=3 route=apple live=false uptimeMs=123400
APOLO_DIAG lifecycle v=1 action=state.playing epoch=3 route=ffmpeg live=false uptimeMs=123900
APOLO_DIAG metric.window v=1 kind=probe.open count=1 total=1 minMs=12 p50Ms=12 p95Ms=12 maxMs=12 uptimeMs=123850
APOLO_DIAG metric.window v=1 kind=http.range count=32 total=32 minMs=10 p50Ms=32 p95Ms=300 maxMs=450 uptimeMs=124000
APOLO_DIAG metric.window v=1 kind=decoder.read count=128 total=160 minMs=1 p50Ms=2 p95Ms=7 maxMs=130 uptimeMs=124500
```

**These are illustrative records, not measured results.**

- `epoch` is the engine's existing playback generation, **not a persistent
  track/user ID**; it changes on load, Next, Previous and Stop. State and
  intent records also contain monotonic `uptimeMs`, route and live/finite flag.
- Four latency domains: `probe.open`, `probe.streamInfo`,
  `http.range` (one measurement per attempt; includes URLSession waiting),
  and `decoder.read` (one buffer or EOF/error per read; includes any blocking
  FFmpeg AVIO work during the read).
- `metric.window` is *opt-in* when a diagnostic handler is installed.
  It stores the **last 128 samples per kind**, emits an initial record, another
  at 8 and then every 32 samples. No unbounded arrays, file handles or timer;
  p50 and p95 use exact nearest-rank calculation **within that sliding window**.
  `count` is window sample size, `total` is events observed since the handler
  was installed. A p95 over 1 sample is not a meaningful performance baseline.
- This window aggregates **across loads for the same handler**. It is NOT an
  exact per-track distribution; old in-flight HTTP work may still complete
  after an epoch changes. Align events by `uptimeMs` and treat attribution
  across concurrent/overlapping loads as uncertain, never fabricate causality.
- No instrumentation was added to `MTAudioProcessingTap.process`, CoreMedia
  callbacks on real-time threads, or decoding algorithms. There is one small
  lock-protected numeric update per sampled I/O/decoder operation; summaries
  pass through the existing Trop logger (which owns disk writing).
- Existing `probe.open`, `http.range`, `renderer.decoderEOF`,
  `renderer.finishScheduled/Fired`, `renderer.slowDecode`,
  `renderer.autoFlush` diagnostics remain and can be correlated by uptime
  and playback epoch where present.

## What these counters DO NOT measure

- **First audible sound.** `state.playing` is not acoustic output.
- True CPU %, peak RSS, retained objects, heap allocation rate, energy or
  device temperature. Neither CI success nor `decoder.read p95` proves these.
- Per-frame PCM fidelity, Atmos spatial output, Dolby decoding on hardware,
  sample-accurate seek, or zero-gap transitions.
- Network time exclusively: a `decoder.read` may include synchronous Range
  requests. **Do not add `http.range + decoder.read` as independent delays**.

## G0 validation plan: no extra builds until separately authorized

1. Confirm the PR's Swift tests and iOS Simulator CI are green.
2. With an explicit diagnostic QA build later, from a real iPhone run a finite
   native AAC, downloaded FLAC, remote FLAC, Ogg/Opus and ICY radio, then
   pause/seek/Next/Stop and collect session exports. **Record codec, route,
   iOS build, source class, bitrate/sample rate, network and Bluetooth route in
   a separate private test note, not in public logs with signed links.**
3. Intentionally stall a **controlled** HTTP 206 test server, compare
   p50/p95/maximum request latency and elapsed user Stop/Next time measured
   end-to-end; the first metric is NOT a Stop latency benchmark.
4. Run a device-appropriate profiler in remote CI/macOS infrastructure when
   available for RSS/allocations/CPU; device energy and thermal measurements
   require suitable hardware or coarse device observations clearly labeled as
   proxies, not invented percentages.
5. Compare like-for-like baseline versus instrumented beta to quantify logging
   overhead and make sure logging cannot cause dropouts.

## Privacy and storage

The host controls log persistence, retention and export; this PR creates no
remote uploads and no new files. The **existing Trop log outside APOLO_DIAG
contains other categories which may include media identifiers, URLs or
credentials**. Never publish a complete raw log without sanitizing it first.
Avoid source URL, HTTP request headers, token/query and track identifiers in
new metrics. FileLog rotation is ~1 MB per process log and keeps one preceding
launch, so do not assume an exported file contains an entire long session.

## Deployment and rollback

- Instrumentation lives in `diag/apolo-g0-measurement-windows-20261123`.
- **No main branch, binary, IPA, audio behavior or package dependency changed**.
- If a diagnostic build proves intrusive, omit the PR/revert the diagnostic
  commit only; no data model or user library migration is involved.
- Keep audit issue #22 and its B01–B25 backlog unchanged until G0's evidence
  gates close, then prioritize any future fixes separately.
