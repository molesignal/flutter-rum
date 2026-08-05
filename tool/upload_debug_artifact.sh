#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 9 ]]; then
  echo "usage: $0 <site> <admin-token> <application> <service> <release> <kind> <platform> <architecture> <file>" >&2
  exit 64
fi

site=$1
admin_token=$2
application=$3
service=$4
release=$5
kind=$6
platform=$7
architecture=$8
artifact=${9:-}

if [[ -z "$artifact" || ! -f "$artifact" ]]; then
  echo "debug artifact does not exist: $artifact" >&2
  exit 66
fi

if [[ -z "${MOLESIGNAL_DEBUG_ID:-}" ]]; then
  echo "MOLESIGNAL_DEBUG_ID is required" >&2
  exit 64
fi

curl --fail-with-body --silent --show-error \
  -H "Authorization: Bearer $admin_token" \
  -F "application_id=$application" \
  -F "service=$service" \
  -F "release=$release" \
  -F "kind=$kind" \
  -F "platform=$platform" \
  -F "architecture=$architecture" \
  -F "debug_id=$MOLESIGNAL_DEBUG_ID" \
  -F "file=@$artifact" \
  "${site%/}/api/v1/debug-artifacts"
