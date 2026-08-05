# Changelog

## 0.3.0

- Add stable application/service/version/platform/architecture/debug-ID build
  identity to every session, action, resource, error, and replay event.
- Validate application-bound `msrum_<16>_<32>` credentials and persist a
  non-secret local application binding to catch accidental token reuse.
- Add privacy-safe structured Flutter AOT, Android native, Apple dSYM, and
  Flutter Web sourcemap frames with public native-frame forwarding support.
- Persist session sampling, counters, event/replay sequences, close state, and
  final aggregates across backgrounding and process restarts.
- Persist standard and replay queues with item/byte/TTL bounds, exponential
  backoff with jitter, idempotent replay segments, and bounded flush results.
- Measure HTTP resources through response-body completion/cancellation and add
  stable DNS/TLS/timeout/cancel/connection/HTTP error fields.
- Add explicit-over-automatic interaction deduplication and duplicate-view
  suppression.
- Define microsecond/byte performance metrics with monotonic versus epoch clock
  metadata and reject invalid negative, overflowing, or malformed values.
- Harden URL, context, stack, diagnostic, and offline-state sanitization so
  credentials, sensitive query values, and developer-machine paths are not
  recorded.

## 0.2.0

- Add sampled Flutter session replay that is playable by the existing rrweb
  player, using full snapshots followed by incremental image mutations.
- Mask all Flutter text and editable fields by default, with explicit
  `RumReplayMask` and `RumReplayBlock` privacy boundaries.
- Add independent replay batching, segment sequence persistence, immutable
  retry payloads, and the `/api/v1/rum/replay` upload contract.
- Add automatic root-level tap tracking plus rage-click and visual dead-click
  detection through `RumApp`.
- Add per-view Flutter time-to-first-render metrics and retain slow-frame
  reporting under the Web-compatible `trackLongTasks` option.
- Add manual replay start/stop controls and a Web-to-Flutter capability map.

## 0.1.0

- Add MoleSignal session, action, error, and resource ingestion.
- Add Flutter and platform error capture.
- Add Navigator route, application lifecycle, and slow-frame instrumentation.
- Add a `package:http` wrapper with W3C Trace Context correlation.
- Add session sampling, persistent anonymous identity, batching, retry, privacy
  redaction, custom transport, and `beforeSend` support.
