#!/bin/bash
set -euo pipefail

APP_DIR=${APP_BUILD_DIR:-/app/code/affine}
cd "$APP_DIR"

log() {
  printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*"
}

log "Running AFFiNE pre-deployment migrations"
node ./scripts/self-host-predeploy.js

log "Starting AFFiNE server"
exec node ./dist/main.js
