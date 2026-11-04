# Changelog

## Unreleased

### Breaking changes

- A replay segment sends `sessionId`, in camelCase as the rest of the MoleSignal API. It needs a
  MoleSignal server that reads it; the events keep their fields.

## 0.3.0

### Breaking changes

- `clientToken` takes the new token format, `mspat-<36 lowercase alphanumeric>`. A
  token of the old `msrum_<16>_<32>` format is refused when the client starts. It
  needs a MoleSignal server that issues the new format.

## 0.2.0

The SDK now speaks the MoleSignal RUM event contract (`contracts/rum/events`).
It is not compatible with the 0.1 protocol and needs a receiver that serves
`POST /api/v1/rum/events`.

### Breaking changes

- **One endpoint.** Events go to `POST {site}/api/v1/rum/events` as a JSON array
  (gzip-compressed above 1 KiB where `dart:io` exists). `/api/v1/rum/sessions`,
  `/actions`, and `/errors` are no longer used. `/api/v1/rum/replay` keeps its
  body and adds `service`, `env` (when set) and `version`, so that the server
  can tell whether the application keeps the session. The `x-molesignal-*`
  request headers are gone; `application.id` travels in each event.
- **No session events.** The SDK no longer reports sessions, their start/end,
  counters, or `session_sequence`; the server derives sessions from `view`
  events. Session IDs are UUIDs. The inactivity timeout is now 15 minutes
  (was 30); the 4-hour limit and the persisted, sampled session are unchanged.
- **New event model.** Actions, resources, errors, performance records,
  lifecycle records, and view records of 0.1 are replaced by the contract's
  `view`, `action`, `error`, `resource`, `long_task`, and `vital` events. All
  durations are integer nanoseconds and `date` is epoch milliseconds (0.1 used
  microseconds). Field names follow the contract: `service`, `env`, `version`,
  `build_version`, `build_id`, `session`, `view`, `usr`, `account`, `context`,
  `feature_flags`, `os`, `device`, `connectivity`, `display`, and `sdk`.
- **Public API.**
  - `startView(name, path:, context:)` is now `startView(key, name:, context:)`
    plus `stopView(key)`.
  - `addInteraction` is removed; use `addAction(name, type: RumActionType.tap)`.
    `addAction` takes an optional `RumActionType` and `addError` an optional
    `RumErrorSource`, `type`, and `fingerprint`.
  - `addPerformanceMetric`, `RumPerformanceMetric`, `RumPerformanceMetricKind`,
    `RumMetricUnit`, and `RumMetricClock` are removed. Startup, first build,
    frame, and memory metrics are collected automatically; report your own
    durations with `startDurationVital`/`stopDurationVital`/`addDurationVital`
    and `addTiming`.
  - `RumResource`: `status` is now `statusCode`; `requestSize` and `initiator`
    are removed; `startTime` is new. `RumTraceContext.parentSpanId` is now
    `spanId`.
  - `RumEventKind` now lists the six event types plus `replay`;
    `RumTransportRequest.kind` is a `RumUploadKind` (`events` or `replay`),
    and `RumTransportResponse` carries the response `headers`.
  - `RumInternalContext` drops `platform`, `architecture`, and `debugId` and
    gains `viewId` and `buildId`.
  - `RumConfiguration.trackLongFrames` (the deprecated alias) is removed; use
    `trackLongTasks`. `RumArtifactKind.javascriptSourcemap` is removed and
    `RumStackFrame.artifactKind` is optional: Flutter Web frames carry no
    artifact kind.
  - `RumUserAction.client` is a `MoleSignalRumClient`.
- **Behavior.**
  - Frustrations are `rage_tap` and `error_tap` on the tap action. `rage_click`
    and `dead_click` actions, and the screenshot comparison behind dead
    clicks, are removed.
  - App lifecycle changes are no longer actions. Views end when the app goes to
    the background and are shown again when it returns.
  - The replay stream holds only rrweb records; the RUM marker records that
    0.1 mixed into it are gone.
  - `error.stack` is the stack as text and `error.frames` the structured
    frames (0.1 sent the frames as `error.stack` and the text as
    `error.raw_stack`). The runtime's raw text is sent only with
    `RumPrivacyLevel.allow`; otherwise `error.stack` is rebuilt from the
    sanitized frames.
  - `error.fingerprint` is no longer computed by the SDK; the receiver groups
    errors. Pass `fingerprint:` to `addError` to choose one.
  - A server-rejected event is reported and counted in
    `RumFlushResult.dropped`/`dropReasons['rejected']` instead of being
    retried or silently accepted.
  - A queue persisted by 0.1 is discarded on first start.
- **New dependencies**: `device_info_plus`, `battery_plus`, and
  `connectivity_plus`. `trackDeviceInfo: false` stops the SDK from calling them.

### Added

- `view` entities: `view.id`, `view.revision`, `time_spent`, `is_active`,
  `loading_type`, cumulative `action`/`error`/`crash`/`resource`/`long_task`/
  `frozen_frame`/`frustration` counts, `custom_timings`
  (`addTiming`), `performance.fbc`, `flutter_build_time`, `flutter_raster_time`,
  `refresh_rate_average`/`refresh_rate_min`, `slow_frames_rate`, `freeze_rate`,
  and `memory_average`/`memory_max`. Views are reported again as they change,
  keep their start `date`, and never span two sessions.
- Actions with `target`, `position`, `name_source`, and `frustration`; errors and
  resources that happen while an action is open join it (`action.id` and the
  action's counts).
- `application_start` action and `app_launch` (`ttid`, `cold_start`) vital;
  `startDurationVital`, `stopDurationVital`, `addDurationVital`.
- `long_task` events for slow frames and `is_frozen_frame` for frozen ones.
- Errors with `source`, `type`, `stack`, `frames`, `handling`, `is_crash`
  (platform dispatcher errors), `category`, `source_type: flutter`,
  `error.resource` for failed requests, and `error.meta`. Dart AOT stacks
  (`--split-debug-info`) are parsed into `instruction_addr`, `image_addr`,
  `relative_address`, `build_id`, and `artifact_kind: flutter_symbols` frames.
- `back` actions for the system back button and the swipe-back gesture.
- `session.has_replay` on views once a replay segment of the session was recorded.
- `session.start` (epoch milliseconds) in the `session` of every event. A session
  that starts with the SDK begins when `initRum` is called; a stored session keeps
  its original start across launches.
- `startResource`/`stopResource`/`stopResourceWithError`; `trace_id` and
  `span_id` on resources.
- `setAccount`, `clearAccount`, `getAccount`, `clearGlobalContext`,
  `addFeatureFlagEvaluation`, `stopView`, `addTiming`.
- Common context: `os`, `device` (type, brand, model, architecture, locale,
  time zone, battery level, power-saving mode, memory, CPU count),
  `connectivity`, `display.viewport`, `usr.anonymous_id`, `account`, `context`,
  `feature_flags`, `sdk` (name, version, sample rates), and `build_version`.
  `RumDeviceInfoProvider` replaces the built-in device reader.
- Transport: events that the receiver rejects are reported and never retried;
  `Retry-After` is honored (seconds or HTTP date); a newer view revision replaces
  the waiting ones; gzip request bodies (`compressRequests`).
- Contract tests: every event the SDK sends in the tests is validated against
  `v1.schema.json` (`MOLESIGNAL_CONTRACTS`, default
  `../molesignal/contracts/rum/events`; skipped with a message when absent).

### Fixed

- Apple crash lines print the offset into the image in decimal; it was read as
  hexadecimal.

## 0.1.0-alpha.1

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

- Add MoleSignal session, action, error, and resource ingestion.
- Add Flutter and platform error capture.
- Add Navigator route, application lifecycle, and slow-frame instrumentation.
- Add a `package:http` wrapper with W3C Trace Context correlation.
- Add session sampling, persistent anonymous identity, batching, retry, privacy
  redaction, custom transport, and `beforeSend` support.
