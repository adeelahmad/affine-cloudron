#!/bin/bash
set -euo pipefail

APP_DIR=${APP_BUILD_DIR:-/app/code/affine}
cd "$APP_DIR"
ENV_EXPORT_FILE=${ENV_EXPORT_FILE:-/run/affine/runtime.env}

if [ -f "$ENV_EXPORT_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_EXPORT_FILE"
  set +a
fi

log() {
  printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*"
}

log "Running AFFiNE pre-deployment migrations"
node ./scripts/self-host-predeploy.js

log "Starting AFFiNE server"
exec node ./dist/main.js
