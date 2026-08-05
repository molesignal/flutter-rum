# MoleSignal Flutter RUM

The official MoleSignal Real User Monitoring SDK for Flutter. It shares the
session, action, error, resource, and replay ingestion contract used by
`@molesignal/browser-rum`, with Flutter-native view, interaction, frustration,
rendering-performance, and screen-replay instrumentation.

[简体中文](README.zh-CN.md)

## Capability parity

| Browser RUM | Flutter equivalent |
| --- | --- |
| History views | `RumNavigationObserver` or `startView` |
| Clicks and submits | Automatic taps through `RumApp`, named `RumUserAction` |
| Rage/dead clicks | `rage_click` and visually verified `dead_click` actions |
| Runtime errors | `FlutterError`, `PlatformDispatcher.onError`, and `addError` |
| fetch/XHR resources | `MoleSignalHttpClient` or `addResource` from other interceptors |
| Long Tasks/Web Vitals | Slow frames and per-view Flutter time-to-first-render |
| rrweb DOM replay | Privacy-processed screenshots encoded as rrweb snapshots/mutations |
| W3C trace correlation | Request, response, or `Server-Timing` `traceparent` |

Browser-only metrics such as LCP and CLS are not fabricated. Flutter reports
its corresponding build, raster, vsync, first-render, and slow-frame data.

## Requirements and install

- Flutter 3.35+
- Dart 3.9+
- Android 24+ or iOS 13+ for the default persistent identity store

```yaml
dependencies:
  molesignal_flutter: ^0.3.0
```

## Initialize

Initialize before `runApp`, wrap the root in `RumApp`, and install the
navigation observer:

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final rum = await initRum(
    const RumConfiguration(
      applicationId: 'checkout-mobile',
      clientToken: String.fromEnvironment('MOLESIGNAL_RUM_TOKEN'),
      site: 'https://molesignal.example.com',
      service: 'checkout-app',
      env: 'production',
      version: String.fromEnvironment('MOLESIGNAL_VERSION'),
      architecture: String.fromEnvironment('MOLESIGNAL_ARCHITECTURE'),
      debugId: String.fromEnvironment('MOLESIGNAL_DEBUG_ID'),
      sessionSampleRate: 100,
      sessionReplaySampleRate: 20,
      trackUserInteractions: true,
    ),
  );

  runApp(
    RumApp(
      client: rum,
      child: MaterialApp(
        navigatorObservers: <NavigatorObserver>[
          RumNavigationObserver(rum),
        ],
        routes: <String, WidgetBuilder>{
          '/': (_) => const HomePage(),
          '/checkout': (_) => const CheckoutPage(),
        },
      ),
    ),
  );
}
```

Replay remains opt-in with a default sample rate of zero. Router-based apps
can supply the observer through their router integration or call `startView`.

## Session replay and privacy

Flutter has no DOM. The first captured frame is encoded as rrweb `Meta` and
`FullSnapshot` events; changed frames become incremental image mutations.
Unchanged frames are skipped, and the existing MoleSignal rrweb player can
play the resulting stream.

```dart
const RumConfiguration(
  // ...
  sessionReplaySampleRate: 20,
  sessionReplay: RumSessionReplayConfiguration(
    captureInterval: Duration(seconds: 2),
    captureOnAction: true,
    pixelRatio: 0.75,
    maximumImageDimension: 1200,
  ),
)

rum.startSessionReplayRecording();
rum.stopSessionReplayRecording();
```

With the default `RumPrivacyLevel.mask`, `Text`, `RichText`, and editable areas
are covered before PNG encoding. Inputs remain masked even in `allow` mode.
Use an explicit privacy boundary for sensitive images, custom painting, maps,
or platform views:

```dart
RumReplayBlock(child: AccountBalanceCard())
```

Raw unmasked pixels never enter the event queue. Custom-painted text cannot be
identified by Widget type and must be wrapped. Platform-view screenshot
behavior depends on platform composition and should be verified on devices.

Replay uses its own 10-second flush interval, per-session sequence numbers,
approximately 1 MiB segments, and an 8 MiB request ceiling. Retried segments
preserve the exact sequence and payload. Unsent segments are persisted and
resume after process restart; the server can therefore handle duplicate delivery
idempotently by application, session ID, and sequence.

## Context, errors, actions, and HTTP

```dart
rum.setUser(const RumUser(
  id: 'user-42',
  attributes: <String, Object?>{'plan': 'enterprise'},
));
rum.setGlobalContextProperty('region', 'ap-southeast-1');

try {
  await submitOrder();
} catch (error, stackTrace) {
  rum.addError(error, stackTrace: stackTrace);
}

rum.addAction('Checkout submitted');

final http.Client httpClient = MoleSignalHttpClient(
  rum,
  inner: http.Client(),
);
await httpClient.get(Uri.parse('https://api.example.com/orders'));
```

`MoleSignalHttpClient` ends duration only after the response body is consumed,
fails, or is cancelled. It captures sanitized URL, method, monotonic duration,
request/response bytes, status, stable transport error fields, and W3C trace
identifiers. Dio and other clients can call
`addResource` from their interceptor APIs. Errors from additional isolates
must be forwarded to the main isolate and passed to `addError`.

Automatic interaction names are privacy-safe. Use `RumUserAction` when a
business-specific name is needed. An explicit `RumUserAction`/`addInteraction`
wins over the root automatic tap within the deduplication window; identical
view notifications in that window emit once.

Native crash collectors can forward symbol-bearing frames without flattening
them to text:

```dart
rum.addError(
  nativeError,
  frames: const <RumStackFrame>[
    RumStackFrame(
      artifactKind: RumArtifactKind.androidNativeSymbols,
      module: 'libpayments.so',
      relativeAddress: '0x1234',
      debugId: 'elf-build-id',
    ),
  ],
);
```

See [release symbols](doc/release-symbols.md) for Flutter
`--obfuscate --split-debug-info`, dSYM/native symbols, and Flutter Web source
maps. A real-device [production E2E fixture](doc/production-e2e.md) is also
included.

## Ingestion contract

Every request uses `Authorization: Bearer <clientToken>`:

- `POST /api/v1/rum/sessions`
- `POST /api/v1/rum/actions`
- `POST /api/v1/rum/errors`
- `POST /api/v1/rum/replay`

The first three bodies are JSON arrays. Replay uses
`{"application":"...","session_id":"...","seq":1,"events":[...]}`.
Every event carries the same `application`, `service`, `version`, `platform`,
`architecture`, and `debug_id` values used for debug-artifact upload. The SDK
also sends `x-molesignal-application-id`; the receiver rejects a public token
bound to another application.

## Main configuration

| Option | Default | Purpose |
| --- | --- | --- |
| `applicationId`, `clientToken`, `site` | required | Application identity, app-bound RUM token, and endpoint |
| `service` | `applicationId` | Service stored on events |
| `env`, `user`, `globalContext` | unset | Deployment and identity dimensions |
| `version` | `unknown` | Artifact release; set explicitly in production |
| `platform`, `architecture`, `debugId` | detected/stable fallback | Debug-artifact build identity |
| `sessionSampleRate` | `100` | Session sampling percentage |
| `sessionReplaySampleRate` | `0` | Replay percentage within sampled sessions |
| `sessionReplay` | privacy-safe defaults | Capture cadence, resolution, and mask color |
| `trackUserInteractions` | `false` | Automatic root-level taps |
| `trackFrustrations` | interaction setting | Rage/dead tap detection |
| `trackResources` | `true` | HTTP resource collection |
| `trackLongTasks` | `true` | Slow Flutter frames |
| `trackViewPerformance` | `true` | Per-view first-render timing |
| `trackFlutterErrors` / `trackPlatformErrors` | `true` | Framework/root-isolate errors |
| `trackAnonymousUser` | `true` | Persistent anonymous identity |
| `defaultPrivacyLevel` | `mask` | Replay text and raw-stack policy |
| `flushInterval` / `batchSize` | `5 s` / `50` | Standard event transport |
| `replayFlushInterval` / `replayBatchSize` | `10 s` / `100` | Replay transport |
| `maxQueueSize` / `maxQueueBytes` / `queueItemTtl` | `1000` / `32 MiB` / `24 h` | Persistent offline bounds |
| `requestTimeout` / `flushTimeout` | `15 s` / `20 s` | Bounded upload and lifecycle flush |
| `beforeSend` | unset | Modify or drop all event kinds, including replay |

URL filtering, trace allowlists, queue limits, timeouts, diagnostics, custom
transport, and persistence are also configurable. `trackLongFrames` remains a
compatibility alias for `trackLongTasks`.

`flush()` and `stop()` return `RumFlushResult`, which separates accepted,
retried, dropped, remaining, timed-out, and per-reason drop counts. Session ID,
sampling decisions, counters, event/replay sequences, last activity, and close
state survive restart. A final session event reports duration, view/action/error/
resource counts, crash state, end reason, and last page.

## Performance field contract

Durations (`cold_start`, `warm_start`, `view_load`, `slow_frame`,
`frozen_frame`, `jank`, `anr`, and `network`) use integer microseconds from a
monotonic clock. Memory uses bytes; counts use `count`. Event timestamps use
epoch microseconds and are never used to derive durations. Platform plugins can
send ANR, memory, or warm-start values with `addPerformanceMetric`; negative,
non-finite, overflowing, and invalid timestamp values are rejected before
serialization.

## Security

- URL queries and fragments are removed by default.
- Sensitive context keys are recursively redacted.
- Raw stack text is disabled by default.
- Credentials, Authorization values, URL user info, sensitive query values,
  request/response bodies, and developer-machine absolute paths are not stored
  in events, diagnostics, replay metadata, or the offline queue.
- `clientToken` ships in the app and must be treated as public. Use the
  application-bound `msrum_<16 alphanumeric>_<32 alphanumeric>` client token
  created by the data-source guide. A non-secret local binding catches accidental
  reuse with a different application; the server remains authoritative.
- Shared preferences are not an encrypted secret store. Queued payloads are
  already privacy-filtered; applications requiring encrypted-at-rest storage
  should provide an encrypted `RumPersistence` implementation.

## Supported production targets

The SDK contract covers Android (`arm64`, `armv7`, `x86_64`), iOS (`arm64`),
and Flutter Web JavaScript. Validate the actual OS/ABI combinations supported
by your application with the production fixture. Web frames use
`javascript_sourcemap` with `platform=flutter` and never masquerade as mobile
AOT. uni-app is not part of this package.

## Development

```bash
flutter pub get
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
```
