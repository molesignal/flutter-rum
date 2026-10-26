# MoleSignal Flutter RUM

The official MoleSignal Real User Monitoring SDK for Flutter. It sends the
MoleSignal RUM event contract (`view`, `action`, `error`, `resource`,
`long_task`, and `vital` events) to `POST /api/v1/rum/events`, the same
contract `@molesignal/browser-rum` uses, with Flutter-native views, taps,
frustration signals, rendering performance, mobile vitals, and screen replay.

[简体中文](README.zh-CN.md)

## Capability parity

| Browser RUM | Flutter equivalent |
| --- | --- |
| History views (`view`) | `RumNavigationObserver` or `startView`; each view is reported again as it changes |
| Clicks (`action`) | Automatic taps through `RumApp`, named `RumUserAction`, `addAction` |
| Rage and error clicks | `rage_tap` and `error_tap` frustrations on the tap action |
| Runtime errors (`error`) | `FlutterError`, `PlatformDispatcher.onError` (a crash), `addError`, failed requests |
| fetch/XHR (`resource`) | `MoleSignalHttpClient`, `startResource`/`stopResource`, `addResource` |
| Long Tasks (`long_task`) | Slow frames, and frozen frames flagged `is_frozen_frame` |
| Web Vitals (`vital`) | Cold start `app_launch` (`ttid`), first build complete, frame and memory metrics on the view; `startDurationVital` for your own |
| rrweb DOM replay | Privacy-processed screenshots encoded as rrweb snapshots/mutations |
| W3C trace correlation | Request, response, or `Server-Timing` `traceparent` on `resource.trace_id`/`span_id` |

Browser-only metrics such as LCP and CLS are not fabricated. Flutter reports
its corresponding build, raster, refresh-rate, slow/frozen frame, and memory
data.

## Requirements and install

- Flutter 3.35+
- Dart 3.9+
- Android 24+ or iOS 13+ for the default persistent identity store

```yaml
dependencies:
  molesignal_flutter: ^0.2.0
```

Device brand, model, OS version, battery level, and connectivity are read with
`device_info_plus`, `battery_plus`, and `connectivity_plus`, which the package
depends on. Set `trackDeviceInfo: false` to send only what Flutter itself
exposes (OS name, locale, time zone offset, screen size, architecture).

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
      buildVersion: String.fromEnvironment('MOLESIGNAL_BUILD_VERSION'),
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

Call `initRum` as early as possible: the cold-start time is measured from it to
the first frame. Replay remains opt-in with a default sample rate of zero.
Router-based apps can supply the observer through their router integration or
call `startView`.

`applicationId` must be the application the `clientToken` (`msrum_…`) is bound
to; it is sent as `application.id` and the receiver rejects events that name
another application.

## Sessions

A session is identified by a UUID kept in shared preferences. It ends after 15
minutes without activity or 4 hours in total, and is sampled once, when it
starts (`sessionSampleRate`). The SDK sends no session event: MoleSignal derives
sessions from the events themselves. Every event carries `session.id`,
`session.type`, and `session.start` (when the session began, in epoch
milliseconds, which lets the receiver tell a session that just began from one
it lost track of); `view` events also carry `session.has_replay` (true once a
replay segment of the session was recorded). A session that starts with the SDK
begins when `initRum` is called, and a stored one keeps its original start
across app launches. A view never spans two sessions: when a session is renewed under a showing
view, that view ends and the same screen continues in a new view with
`loading_type: session_renewal`.

## Views

```dart
rum.startView('/checkout', name: 'Checkout');
rum.addTiming('cart_ready');          // view.custom_timings
rum.stopView('/checkout');
```

`view.url` is the route path (query and fragment removed unless
`trackUrlQueryString`), `view.name` the name. Starting a view ends the previous
one. A view is reported again, with `view.revision` one higher and the counts so
far, whenever something in it changed: at most once per `flushInterval`, and
immediately when it starts, ends, or the app is flushed. `date` stays the start
of the view. Views end when the app goes to the background and are shown again
(`view_controller_redisplay`) when it returns.

A view carries `time_spent`, `is_active`, `loading_type`, the counts
(`action`, `error`, `crash`, `resource`, `long_task`, `frozen_frame`,
`frustration`), `custom_timings`, and the Flutter metrics listed under
[Performance fields](#performance-fields). Events that happen before the first
`startView` belong to an `ApplicationLaunch` view.

## Actions, errors, resources, and vitals

```dart
rum.setUser(const RumUser(id: 'user-42', attributes: {'plan': 'enterprise'}));
rum.setAccount(const RumAccount(id: 'acme', name: 'Acme'));
rum.setGlobalContextProperty('region', 'ap-southeast-1');
rum.addFeatureFlagEvaluation('new_checkout', true);

rum.addAction('Checkout submitted', context: {'cart_size': 3});

try {
  await submitOrder();
} catch (error, stackTrace) {
  rum.addError(error, stackTrace: stackTrace, context: {'step': 'payment'});
}

rum.startDurationVital('checkout_form_ready');
// ...
rum.stopDurationVital('checkout_form_ready');
rum.addDurationVital('cart_sync', const Duration(milliseconds: 640));

final http.Client httpClient = MoleSignalHttpClient(rum, inner: http.Client());
await httpClient.get(Uri.parse('https://api.example.com/orders'));
```

**Actions** are `tap`, `custom`, `back`, and the automatic `application_start`.
Automatic taps use the generic name `Tap` (`name_source: mask_placeholder`) so no
screen content is read; use `RumUserAction` for a business name. The system
back button and the iOS swipe-back gesture are `back` actions. A tap stays open
while the requests it started are in flight (at most 5 s) and for 100 ms after
the last thing it caused; the errors, crashes, and resources in that time carry
its `action.id`, and the action reports their counts. Three taps within 50
logical pixels in a second make the last a `rage_tap`; a tap that caused an
error is an `error_tap`. An explicit `RumUserAction` wins over the automatic
tap of the same gesture within `actionDeduplicationWindow`.

**Errors** carry `source`, `type`, `message`, `stack`, structured `frames`, and
`handling`. Framework errors are `source: source`, `handling: unhandled`;
`PlatformDispatcher.onError` errors are also `is_crash: true`. `addError`
reports `handling: handled` with the `source` you choose (default `custom`). A
request that failed before a response is a `network` error with
`error.resource` (`method`, `status_code: 0`, `url`); an HTTP error status is
only a resource. All errors have `source_type: flutter`. Errors from additional
isolates must be forwarded to the main isolate and passed to `addError`. The
SDK does not set `error.fingerprint`; pass `fingerprint:` to override grouping.

**Resources** are `type: native` with `method`, `status_code`, `duration`,
`size` (response bytes), and `trace_id`/`span_id`. `MoleSignalHttpClient` ends
the duration only after the response body is consumed, fails, or is cancelled.
Dio and other clients can call `startResource`/`stopResource` from their
interceptors, or `addResource` for a finished request.

**Vitals**: the first frame after `initRum` is the cold start, reported as an
`application_start` action and an `app_launch` vital (`app_launch_metric: ttid`,
`startup_type: cold_start`). `startDurationVital`/`stopDurationVital` and
`addDurationVital` report `duration` vitals.

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

Replay segments go to `POST /api/v1/rum/replay` with their own 10-second flush
interval, per-session sequence numbers, approximately 1 MiB segments, and an
8 MiB request ceiling. Retried segments preserve the exact sequence and
payload. Unsent segments are persisted and resume after process restart; the
server can therefore handle duplicate delivery idempotently by application,
session ID, and sequence. Each request also says the configured `service`,
`env` (when set) and `version`, so that the server can tell whether the
application keeps the session. The stream holds only rrweb records; the RUM
events that describe the session are in the events upload.

## Intake contract

Events are batched into a JSON array and sent to
`POST {site}/api/v1/rum/events` with `Authorization: Bearer <clientToken>`.
`site` may already include `/api`, `/api/v1`, or `/api/v1/rum`; the path is
completed. Batches of more than 1 KiB are gzip-compressed
(`Content-Encoding: gzip`) where `dart:io` is available
(`compressRequests: false` turns it off). A request holds at most 48 KiB of
events (one larger event goes alone), far below the receiver's 5000 events and
5 MiB limits.

The receiver answers `{"accepted": n, "rejected": [{"index": i, "reason": "…"}]}`:

- A **rejected** event is reported (`RumConfiguration.onError`, and
  `RumFlushResult.dropped`/`dropReasons['rejected']`) and never sent again.
- Network errors, timeouts, `408`, `429`, and `5xx` are retried with
  exponential backoff and jitter, never sooner than the `Retry-After` the
  receiver sent. Events survive in the persisted offline queue.
- Any other `4xx` drops the batch (`non_retryable`).

The queue is bounded by item count, bytes, and age (`maxQueueSize`,
`maxQueueBytes`, `queueItemTtl`); a newer revision of a view replaces the
waiting older ones.

All durations, and every time relative to the start of a view, are **integer
nanoseconds**; `date` is epoch milliseconds. Every event carries:

| Field | Value |
| --- | --- |
| `source` | `flutter` |
| `application.id` | `applicationId` |
| `service`, `env`, `version`, `build_version`, `build_id` | configuration; `build_id` is `debugId` |
| `session` | `id`, `type: user`, `start` (epoch ms), and `has_replay` on views |
| `view` | `id`, `url`, `name`, `in_foreground` (the view itself on `view` events) |
| `action.id` | on events caused by an action |
| `usr` | `setUser` plus a persistent `anonymous_id`; extra attributes are kept |
| `account` | `setAccount` |
| `os` | `name`, `version`, `version_major`, `build` |
| `device` | `type` (`mobile`/`tablet`/`desktop`), `brand`, `model`, `architecture`, `locale`, `time_zone` (`UTC+08:00`), `battery_level`, `power_saving_mode`, `is_low_ram`, `total_ram`, `logical_cpu_count` |
| `connectivity` | `status` and `interfaces` |
| `display.viewport` | logical `width`/`height` |
| `sdk` | `name: molesignal_flutter`, `version`, `session_sample_rate`, `replay_sample_rate` |
| `context` | global context merged with the event's attributes |
| `feature_flags` | `addFeatureFlagEvaluation` values |

## Performance fields

| Field | Meaning |
| --- | --- |
| `view.performance.fbc.timestamp` | First build complete: ns from the start of the view to the end of the first frame built for it |
| `view.flutter_build_time`, `flutter_raster_time` | `min`/`max`/`average` ns of the UI-thread build and raster-thread work per frame |
| `view.refresh_rate_average`, `refresh_rate_min` | Frames per second the frames could sustain, capped at the display refresh rate |
| `view.slow_frames_rate` | ms spent in slow frames (over the frame budget, under the frozen threshold) per second of view |
| `view.freeze_rate` | seconds spent in frozen frames per hour of view |
| `view.memory_average`, `memory_max` | Resident set size in bytes (not on Flutter Web) |
| `long_task.duration`, `is_frozen_frame` | A frame of at least `longFrameThreshold` (100 ms), frozen from `frozenFrameThreshold` (700 ms) |
| `vital app_launch` | Cold start: ns from `initRum` to the end of the first frame built for the application's UI |

Startup and first build are measured with the framework's post-frame
callbacks, so they work the same on every platform. The frame metrics come from
Flutter's frame timings, which the engine reports in batches (Flutter Web
reports them late and only on its monotonic clock), so a `long_task` is always
dated inside the view it happened in.

## Main configuration

| Option | Default | Purpose |
| --- | --- | --- |
| `applicationId`, `clientToken`, `site` | required | Application identity, app-bound RUM token, and endpoint |
| `service` | `applicationId` | `service` |
| `env`, `user`, `globalContext` | unset | Deployment and identity dimensions |
| `version`, `buildVersion` | `unknown`, unset | `version` (the artifact release) and `build_version` |
| `platform`, `architecture`, `debugId` | detected/stable fallback | Stack parsing, `device.architecture`, `build_id`, frame `debug_id` |
| `sessionSampleRate` | `100` | Session sampling percentage |
| `sessionReplaySampleRate` | `0` | Replay percentage within sampled sessions |
| `sessionReplay` | privacy-safe defaults | Capture cadence, resolution, and mask color |
| `trackUserInteractions` | `false` | Automatic root-level taps and `back` actions |
| `trackFrustrations` | interaction setting | `rage_tap` and `error_tap` |
| `trackResources` | `true` | HTTP resource collection |
| `trackLongTasks` | `true` | Slow and frozen frames as `long_task` events, and the view's `long_task`/`frozen_frame` counts |
| `trackViewPerformance` | `true` | Startup, first build, frame, and memory metrics |
| `trackDeviceInfo` | `true` | Brand, model, battery, connectivity through plugins |
| `trackFlutterErrors` / `trackPlatformErrors` | `true` | Framework/root-isolate errors |
| `trackAppLifecycle` | `true` | Views end in the background; background flush |
| `trackAnonymousUser` | `true` | Persistent `usr.anonymous_id` |
| `trackUrlQueryString` | `false` | Keep URL queries |
| `defaultPrivacyLevel` | `mask` | Replay text and raw-stack policy |
| `sessionInactivityTimeout` / `maxSessionDuration` | `15 min` / `4 h` | Session limits |
| `flushInterval` / `batchSize` | `5 s` / `50` | Standard event transport |
| `replayFlushInterval` / `replayBatchSize` | `10 s` / `100` | Replay transport |
| `maxQueueSize` / `maxQueueBytes` / `queueItemTtl` | `1000` / `32 MiB` / `24 h` | Persistent offline bounds |
| `retryInitialDelay` / `retryMaxDelay` | `1 s` / `1 min` | Backoff |
| `requestTimeout` / `flushTimeout` | `15 s` / `20 s` | Bounded upload and lifecycle flush |
| `compressRequests` | `true` | gzip event batches |
| `beforeSend` | unset | Modify or drop all event kinds, including replay |

URL filtering (`excludedUrls`, `allowedTracingUrls`), thresholds, diagnostics
(`onError`), custom `transport`, `persistence`, and `deviceInfoProvider` are
also configurable.

`flush()` and `stop()` return `RumFlushResult`, which separates accepted,
retried, dropped, remaining, timed-out, and per-reason drop counts. `stop()`
ends the active view with a last report. The session ID, sampling decisions,
last activity, and replay sequence survive restart.

## Security

- URL queries and fragments are removed by default.
- Sensitive context keys are recursively redacted.
- Raw stack text is only sent with `RumPrivacyLevel.allow`; otherwise
  `error.stack` is rebuilt from the sanitized frames.
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
by your application with the production fixture. Web frames name a file and
carry no native `artifact_kind`, so they are never mistaken for mobile AOT.
uni-app is not part of this package.

## Development

```bash
flutter pub get
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
```

The tests check every event the SDK sends against the shared event contract
(`v1.schema.json`). Point `MOLESIGNAL_CONTRACTS` at the server repository's
`contracts/rum/events` directory; the default is
`../molesignal/contracts/rum/events`. When it cannot be found, the contract
tests are skipped with that message.

## Upgrading from 0.1

0.2.0 has no compatibility with the 0.1 protocol; see the
[changelog](CHANGELOG.md) for every breaking change.
