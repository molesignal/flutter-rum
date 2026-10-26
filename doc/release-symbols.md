# Flutter release symbols and build identity

MoleSignal matches an error frame to a debug artifact with the same
`application_id`, `service`, release (`version`), `kind`, `platform`,
`architecture`, and `debug_id`. The values passed to `RumConfiguration` must
therefore come from the same CI build that produced the uploaded artifact.

The SDK sends them with every error event as `application.id`, `service`,
`version`, `build_id` (the `debugId`), `os.name`, and `device.architecture`,
and on each frame as `artifact_kind`, `debug_id` (the `debugId`, or the frame's
own), and the addresses a symbol file resolves.

## Recommended CI values

Pass immutable values with `--dart-define` and use them in configuration:

```dart
const RumConfiguration(
  applicationId: 'checkout-mobile',
  clientToken: String.fromEnvironment('MOLESIGNAL_RUM_TOKEN'),
  site: String.fromEnvironment('MOLESIGNAL_SITE'),
  service: 'checkout-app',
  version: String.fromEnvironment('MOLESIGNAL_VERSION'),
  architecture: String.fromEnvironment('MOLESIGNAL_ARCHITECTURE'),
  debugId: String.fromEnvironment('MOLESIGNAL_DEBUG_ID'),
)
```

`platform` is detected as `android`, `ios`, or `flutter` (Flutter Web) and
decides how stack traces are parsed. `architecture` (sent as
`device.architecture`) is detected at runtime, but release pipelines should
pass its canonical value explicitly: `arm64`, `armv7`, `x86_64`, `javascript`,
or `wasm32`. Generate a new `debug_id` for every build whose code can differ, and
use exactly that value for every artifact belonging to that build. The
architecture remains a separate matching key, so a multi-ABI build may use one
build ID with one artifact per architecture.

When `version`, `architecture`, or `debugId` is omitted, the SDK sends a stable
fallback rather than a missing field. Those fallbacks are useful for debug
builds but should not be used for production symbolication.

## Android AOT symbols

Build each production ABI with obfuscation and split debug information:

```bash
flutter build apk \
  --release \
  --obfuscate \
  --split-debug-info=build/molesignal-symbols/android-arm64 \
  --target-platform=android-arm64 \
  --dart-define=MOLESIGNAL_VERSION=1.4.0+42 \
  --dart-define=MOLESIGNAL_ARCHITECTURE=arm64 \
  --dart-define=MOLESIGNAL_DEBUG_ID="$BUILD_ID" \
  --dart-define=MOLESIGNAL_RUM_TOKEN="$RUM_TOKEN"
```

With `--split-debug-info` the Dart runtime prints stack traces without names:
a header with the `build_id` and `isolate_dso_base` of the running image, then
one `#00 abs <address> virt <address> …` line per frame. The SDK keeps what a
symbol file needs from them: each frame has `artifact_kind: flutter_symbols`,
`instruction_addr` (absolute), `image_addr` (the image base), and
`relative_address` (`virt`), and the runtime's `build_id` next to the
configured `debug_id`; the receiver finds the symbol file by `debug_id` and
falls back to `build_id`. A build without `--split-debug-info` (a debug build,
or a release build made without it) prints readable frames (`function`,
`file`, `line`, `column`), which name no artifact.

Upload the generated `app.android-arm64.symbols` as:

- `kind=flutter_symbols`
- `platform=android`
- `architecture=arm64`
- `debug_id=$BUILD_ID`

Upload native plugin ELF symbols separately as
`kind=android_native_symbols`. Forward native crash frames with
`RumStackFrame(artifactKind: RumArtifactKind.androidNativeSymbols, ...)` and
include the module plus instruction/image/relative addresses supplied by the
native crash collector. A frame-specific debug ID overrides the event build ID.

## iOS AOT and dSYM

```bash
flutter build ipa \
  --release \
  --obfuscate \
  --split-debug-info=build/molesignal-symbols/ios-arm64 \
  --dart-define=MOLESIGNAL_VERSION=1.4.0+42 \
  --dart-define=MOLESIGNAL_ARCHITECTURE=arm64 \
  --dart-define=MOLESIGNAL_DEBUG_ID="$BUILD_ID" \
  --dart-define=MOLESIGNAL_RUM_TOKEN="$RUM_TOKEN"
```

Upload `app.ios-arm64.symbols` as `flutter_symbols`, `platform=ios`, and
`architecture=arm64`. Upload native dSYM bundles as `apple_dsym`; forwarded
native frames use `RumArtifactKind.appleDsym` and the dSYM UUID as their
frame-specific `debugId` when it differs from the Flutter build ID.

## Flutter Web

Flutter Web is deliberately separate from mobile AOT:

```bash
flutter build web \
  --release \
  --source-maps \
  --dart-define=MOLESIGNAL_VERSION=1.4.0+42 \
  --dart-define=MOLESIGNAL_ARCHITECTURE=javascript \
  --dart-define=MOLESIGNAL_DEBUG_ID="$BUILD_ID" \
  --dart-define=MOLESIGNAL_RUM_TOKEN="$RUM_TOKEN"
```

Upload `main.dart.js.map` as `kind=javascript_sourcemap`, `platform=flutter`,
`architecture=javascript`. Web frames have `file`, `function`, one-based `line`
and `column`, and the `debug_id`, and **no `artifact_kind`**: the receiver takes
a frame with a `file` and a `line` but no `artifact_kind` for a JavaScript frame
(the contract's `javascript_sourcemap` value says the same) and finds the
source map by `debug_id`, else by file name, as it does for browser errors.
File names are sent without credentials or query strings. Native address
fields are not sent for `platform=flutter`, so a future Wasm address cannot
accidentally select a mobile `flutter_symbols` artifact. Wasm symbolication
requires a JavaScript/source-map location until the receiver gains a dedicated
Wasm artifact kind.

## Upload helper

The helper uses an administrative token with `streams.configure`; never use the
public RUM token for artifact management:

```bash
export MOLESIGNAL_DEBUG_ID="$BUILD_ID"
tool/upload_debug_artifact.sh \
  "$MOLESIGNAL_SITE" "$ADMIN_TOKEN" \
  checkout-mobile checkout-app 1.4.0+42 \
  flutter_symbols android arm64 \
  build/molesignal-symbols/android-arm64/app.android-arm64.symbols
```

Missing, stale, wrong-architecture, wrong-release, or wrong-debug-ID artifacts
do not cause the SDK to discard the error. MoleSignal preserves the sanitized
original frame, records a missing/partial symbolication state, and appends
`original_*` fields to the frame only when translation succeeds.
