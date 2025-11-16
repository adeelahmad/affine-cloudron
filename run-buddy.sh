#!/bin/bash
set -euo pipefail

ENV_EXPORT_FILE=${ENV_EXPORT_FILE:-/run/affine/runtime.env}

if [ -f "$ENV_EXPORT_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_EXPORT_FILE"
  set +a
fi

exec /usr/bin/manticore-buddy "$@"
