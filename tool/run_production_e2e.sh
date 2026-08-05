#!/usr/bin/env bash
set -euo pipefail

target=${1:-}
device=${2:-}
if [[ "$target" != "android" && "$target" != "ios" ]]; then
  echo "usage: $0 <android|ios> <device-id>" >&2
  exit 64
fi
if [[ -z "$device" ]]; then
  echo "device-id is required" >&2
  exit 64
fi

required=(
  MOLESIGNAL_APPLICATION_ID
  MOLESIGNAL_RUM_TOKEN
  MOLESIGNAL_SITE
  MOLESIGNAL_SERVICE
  MOLESIGNAL_VERSION
  MOLESIGNAL_ARCHITECTURE
  MOLESIGNAL_DEBUG_ID
)
for name in "${required[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    echo "$name is required" >&2
    exit 64
  fi
done

script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(cd -- "$script_dir/.." && pwd)
example_dir="$project_dir/example"
symbols_dir="$example_dir/build/molesignal-symbols/$target-$MOLESIGNAL_ARCHITECTURE"
target_file=integration_test/production_e2e_test.dart
defines=(
  "--dart-define=MOLESIGNAL_APPLICATION_ID=$MOLESIGNAL_APPLICATION_ID"
  "--dart-define=MOLESIGNAL_RUM_TOKEN=$MOLESIGNAL_RUM_TOKEN"
  "--dart-define=MOLESIGNAL_SITE=$MOLESIGNAL_SITE"
  "--dart-define=MOLESIGNAL_SERVICE=$MOLESIGNAL_SERVICE"
  "--dart-define=MOLESIGNAL_VERSION=$MOLESIGNAL_VERSION"
  "--dart-define=MOLESIGNAL_ARCHITECTURE=$MOLESIGNAL_ARCHITECTURE"
  "--dart-define=MOLESIGNAL_DEBUG_ID=$MOLESIGNAL_DEBUG_ID"
)
for name in \
  MOLESIGNAL_NATIVE_ARTIFACT_KIND \
  MOLESIGNAL_NATIVE_MODULE \
  MOLESIGNAL_NATIVE_RELATIVE_ADDRESS; do
  if [[ -n "${!name:-}" ]]; then
    defines+=("--dart-define=$name=${!name}")
  fi
done

cd "$example_dir"
mkdir -p "$symbols_dir"

if [[ "$target" == "android" ]]; then
  case "$MOLESIGNAL_ARCHITECTURE" in
    arm64) flutter_architecture=arm64 ;;
    armv7) flutter_architecture=arm ;;
    x86_64) flutter_architecture=x64 ;;
    *)
      echo "unsupported Android architecture: $MOLESIGNAL_ARCHITECTURE" >&2
      exit 64
      ;;
  esac
  flutter build apk \
    --release \
    --obfuscate \
    --split-debug-info="$symbols_dir" \
    --target-platform="android-$flutter_architecture" \
    --target="$target_file" \
    "${defines[@]}"
  flutter drive \
    --device-id="$device" \
    --release \
    --driver=test_driver/integration_test.dart \
    --target="$target_file" \
    --use-application-binary=build/app/outputs/flutter-apk/app-release.apk
else
  flutter build ipa \
    --release \
    --obfuscate \
    --split-debug-info="$symbols_dir" \
    --target="$target_file" \
    "${defines[@]}"
  ipa=$(find build/ios/ipa -maxdepth 1 -name '*.ipa' -print -quit)
  if [[ -z "$ipa" ]]; then
    echo "release IPA was not produced" >&2
    exit 66
  fi
  flutter drive \
    --device-id="$device" \
    --release \
    --driver=test_driver/integration_test.dart \
    --target="$target_file" \
    --use-application-binary="$ipa"
fi

echo "production E2E passed; symbols are in $symbols_dir"
