# Production-build E2E fixture

The fixture in `example/integration_test/production_e2e_test.dart` runs against
a real MoleSignal receiver. It emits a caught Dart release failure and can also
forward one native frame obtained from an Android/iOS crash fixture. The test
fails when ingestion is rejected, times out, or leaves persisted events.

## One-time example platform setup

The repository keeps the example small. Generate the platform runners before a
device job (normally in a clean CI checkout):

```bash
cd example
flutter create --platforms=android,ios,web \
  --project-name=molesignal_flutter_example \
  --org=com.molesignal .
flutter pub get
```

Do not accept a generated `lib/main.dart` replacement; the checked-in example
is the fixture entry point.

## Required environment

```bash
export MOLESIGNAL_APPLICATION_ID=checkout-mobile
export MOLESIGNAL_RUM_TOKEN=msrum_... # application-bound public token
export MOLESIGNAL_SITE=https://molesignal.example.com
export MOLESIGNAL_SERVICE=checkout-app
export MOLESIGNAL_VERSION=1.4.0+42
export MOLESIGNAL_ARCHITECTURE=arm64
export MOLESIGNAL_DEBUG_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
```

Run a release, obfuscated, split-debug-info build on a real device:

```bash
tool/run_production_e2e.sh android <device-id>
tool/run_production_e2e.sh ios <device-id>
```

The script prebuilds the release binary with `--obfuscate` and
`--split-debug-info`, then runs that exact APK/IPA through `flutter drive`.
Upload every generated Flutter symbols file with the helper documented in
`release-symbols.md` before checking the stored error.

For a native frame, the platform crash fixture must expose the symbol-bearing
module and relative address, then set:

```bash
export MOLESIGNAL_NATIVE_ARTIFACT_KIND=android_native_symbols # or apple_dsym
export MOLESIGNAL_NATIVE_MODULE=libfixture.so                 # or Runner
export MOLESIGNAL_NATIVE_RELATIVE_ADDRESS=0x1234
```

After the run, query the `rum_errors` stream with an administrative read token
and assert all of the following:

1. Both markers are scoped to `application=checkout-mobile`; querying another
   application returns neither event.
2. The Dart marker has restored function, file, and line fields and keeps the
   sanitized obfuscated values under `original_*`.
3. The native marker selects the uploaded `android_native_symbols` or
   `apple_dsym` artifact for the exact architecture/debug ID.
4. Re-running the same Replay segment (when Replay is enabled for an extended
   job) is idempotent by `(application, session_id, seq)`.

Device jobs should cover Android arm64/armv7/x86_64 as supported by the app,
iOS arm64 on every supported minimum/maximum OS lane, and Flutter Web
JavaScript. Flutter Web uses its own sourcemap build and is not executed by the
mobile helper. uni-app is intentionally outside this SDK's compatibility
matrix.
