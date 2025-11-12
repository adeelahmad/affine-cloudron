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

ensure_database_env() {
  if [ -n "${DATABASE_URL:-}" ] || [ -z "${CLOUDRON_POSTGRESQL_URL:-}" ]; then
    return
  fi
  local db_url="$CLOUDRON_POSTGRESQL_URL"
  if [[ "$db_url" == postgres://* ]]; then
    db_url="postgresql://${db_url#postgres://}"
  fi
  export DATABASE_URL="$db_url"
}

ensure_redis_env() {
  if [ -z "${CLOUDRON_REDIS_URL:-}" ]; then
    return
  fi
  local redis_info
  redis_info=$(python3 - <<'PY'
import os
from urllib.parse import urlparse
url = os.environ.get('CLOUDRON_REDIS_URL')
if not url:
    raise SystemExit('redis url missing')
parsed = urlparse(url)
host = parsed.hostname or 'localhost'
port = parsed.port or 6379
password = parsed.password or ''
db = (parsed.path or '/0').lstrip('/') or '0'
username = parsed.username or ''
print(f"{host}\n{port}\n{password}\n{db}\n{username}")
PY
)
  IFS=$'\n' read -r host port password db username <<<"$redis_info"
  export REDIS_SERVER_HOST="${REDIS_SERVER_HOST:-$host}"
  export REDIS_SERVER_PORT="${REDIS_SERVER_PORT:-$port}"
  export REDIS_SERVER_PASSWORD="${REDIS_SERVER_PASSWORD:-$password}"
  export REDIS_SERVER_DATABASE="${REDIS_SERVER_DATABASE:-$db}"
  export REDIS_SERVER_USERNAME="${REDIS_SERVER_USERNAME:-$username}"
  export REDIS_URL="${REDIS_URL:-$CLOUDRON_REDIS_URL}"
  export REDIS_SERVER_URL="${REDIS_SERVER_URL:-$CLOUDRON_REDIS_URL}"
}

ensure_mail_env() {
  if [ -z "${CLOUDRON_MAIL_SMTP_SERVER:-}" ]; then
    return
  fi
  export MAILER_HOST="${MAILER_HOST:-$CLOUDRON_MAIL_SMTP_SERVER}"
  export MAILER_PORT="${MAILER_PORT:-${CLOUDRON_MAIL_SMTP_PORT:-587}}"
  export MAILER_USER="${MAILER_USER:-${CLOUDRON_MAIL_SMTP_USERNAME:-}}"
  export MAILER_PASSWORD="${MAILER_PASSWORD:-${CLOUDRON_MAIL_SMTP_PASSWORD:-}}"
  export MAILER_SENDER="${MAILER_SENDER:-${CLOUDRON_MAIL_FROM:-AFFiNE <no-reply@cloudron.local>}}"
  export MAILER_SERVERNAME="${MAILER_SERVERNAME:-AFFiNE Server}"
}

ensure_server_env() {
  if [ -n "${AFFINE_SERVER_EXTERNAL_URL:-}" ] || [ -z "${CLOUDRON_APP_ORIGIN:-}" ]; then
    return
  fi
  export AFFINE_SERVER_EXTERNAL_URL="$CLOUDRON_APP_ORIGIN"
  local host
  host=$(python3 - <<PY
from urllib.parse import urlparse
import os
url = os.environ.get('CLOUDRON_APP_ORIGIN', '')
parsed = urlparse(url)
print(parsed.hostname or '')
PY
)
  export AFFINE_SERVER_HOST="$host"
  if [[ "$CLOUDRON_APP_ORIGIN" == https://* ]]; then
    export AFFINE_SERVER_HTTPS=true
  else
    export AFFINE_SERVER_HTTPS=false
  fi
  export AFFINE_INDEXER_ENABLED="${AFFINE_INDEXER_ENABLED:-false}"
}

ensure_runtime_envs() {
  ensure_database_env
  ensure_redis_env
  ensure_mail_env
  ensure_server_env
}

log "Running AFFiNE pre-deployment migrations"
ensure_runtime_envs
node ./scripts/self-host-predeploy.js

log "Starting AFFiNE server"
exec node ./dist/main.js
