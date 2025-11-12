#!/bin/bash
set -euo pipefail

APP_CODE_DIR=${APP_CODE_DIR:-/app/code}
APP_DATA_DIR=${APP_DATA_DIR:-/app/data}
APP_RUNTIME_DIR=${APP_RUNTIME_DIR:-/run/affine}
APP_TMP_DIR=${APP_TMP_DIR:-/tmp/data}
APP_BUILD_DIR=${APP_BUILD_DIR:-/app/code/affine}
APP_HOME_DIR=${APP_HOME_DIR:-/app/data/home}
AFFINE_HOME=${AFFINE_HOME:-$APP_HOME_DIR/.affine}
ENV_EXPORT_FILE=${ENV_EXPORT_FILE:-$APP_RUNTIME_DIR/runtime.env}
export APP_CODE_DIR APP_DATA_DIR APP_RUNTIME_DIR APP_TMP_DIR APP_BUILD_DIR APP_HOME_DIR AFFINE_HOME ENV_EXPORT_FILE

log() {
  printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*"
}

record_env_var() {
  local name="$1"
  local value="$2"
  if [ -n "$value" ]; then
    printf '%s=%q\n' "$name" "$value" >> "$ENV_EXPORT_FILE"
  fi
}

require_env() {
  local var_name="$1"
  if [ -z "${!var_name:-}" ]; then
    echo "Environment variable ${var_name} is not set" >&2
    exit 1
  fi
}

prepare_data_dirs() {
  log "Preparing persistent directories"
  mkdir -p "$APP_DATA_DIR/config" "$APP_DATA_DIR/storage" "$APP_DATA_DIR/logs" "$APP_RUNTIME_DIR" "$APP_HOME_DIR" "$AFFINE_HOME"
  mkdir -p /run/nginx/body /run/nginx/proxy /run/nginx/fastcgi
  : > "$ENV_EXPORT_FILE"

  if [ ! -f "$APP_DATA_DIR/config/config.json" ]; then
    log "Seeding default configuration"
    cp "$APP_TMP_DIR/config/config.json" "$APP_DATA_DIR/config/config.json"
  fi

  local storage_contents=""
  if [ -d "$APP_DATA_DIR/storage" ]; then
    storage_contents=$(ls -A "$APP_DATA_DIR/storage" 2>/dev/null || true)
  fi
  if [ ! -d "$APP_DATA_DIR/storage" ] || [ -z "$storage_contents" ]; then
    cp -a "$APP_TMP_DIR/storage/." "$APP_DATA_DIR/storage/" 2>/dev/null || true
  fi

  rm -rf "$AFFINE_HOME/config" "$AFFINE_HOME/storage"
  ln -sf "$APP_DATA_DIR/config" "$AFFINE_HOME/config"
  ln -sf "$APP_DATA_DIR/storage" "$AFFINE_HOME/storage"

  chown -R cloudron:cloudron "$APP_DATA_DIR" "$APP_RUNTIME_DIR" "$APP_HOME_DIR"
}

configure_database() {
  require_env CLOUDRON_POSTGRESQL_URL
  local db_url="$CLOUDRON_POSTGRESQL_URL"
  if [[ "$db_url" == postgres://* ]]; then
    db_url="postgresql://${db_url#postgres://}"
  fi
  export DATABASE_URL="$db_url"
  record_env_var DATABASE_URL "$db_url"
  log "Configured PostgreSQL endpoint"
}

configure_redis() {
  require_env CLOUDRON_REDIS_URL
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
  export REDIS_SERVER_HOST="$host"
  export REDIS_SERVER_PORT="$port"
  export REDIS_SERVER_PASSWORD="$password"
  export REDIS_SERVER_DATABASE="$db"
  export REDIS_SERVER_USERNAME="$username"
  export REDIS_URL="$CLOUDRON_REDIS_URL"
  export REDIS_SERVER_URL="$CLOUDRON_REDIS_URL"
  record_env_var REDIS_SERVER_HOST "$host"
  record_env_var REDIS_SERVER_PORT "$port"
  record_env_var REDIS_SERVER_PASSWORD "$password"
  record_env_var REDIS_SERVER_DATABASE "$db"
  record_env_var REDIS_SERVER_USERNAME "$username"
  record_env_var REDIS_URL "$CLOUDRON_REDIS_URL"
  record_env_var REDIS_SERVER_URL "$CLOUDRON_REDIS_URL"
  python3 - <<'PY'
import json
import os
from pathlib import Path
config_path = Path(os.environ['APP_DATA_DIR']) / 'config' / 'config.json'
data = json.loads(config_path.read_text())
redis = data.setdefault('redis', {})
redis['host'] = os.environ.get('REDIS_SERVER_HOST', '')
redis['port'] = int(os.environ.get('REDIS_SERVER_PORT') or 6379)
redis['password'] = os.environ.get('REDIS_SERVER_PASSWORD', '')
redis['username'] = os.environ.get('REDIS_SERVER_USERNAME', '')
redis['db'] = int(os.environ.get('REDIS_SERVER_DATABASE') or 0)
config_path.write_text(json.dumps(data, indent=2))
PY
  log "Configured Redis endpoint"
}

configure_mail() {
  if [ -z "${CLOUDRON_MAIL_SMTP_SERVER:-}" ]; then
    log "Cloudron mail addon not configured, skipping SMTP setup"
    return
  fi
  export MAILER_HOST="$CLOUDRON_MAIL_SMTP_SERVER"
  export MAILER_PORT="${CLOUDRON_MAIL_SMTP_PORT:-587}"
  export MAILER_USER="${CLOUDRON_MAIL_SMTP_USERNAME:-}"
  export MAILER_PASSWORD="${CLOUDRON_MAIL_SMTP_PASSWORD:-}"
  export MAILER_SENDER="${CLOUDRON_MAIL_FROM:-AFFiNE <no-reply@cloudron.local>}"
  export MAILER_SERVERNAME="${MAILER_SERVERNAME:-AFFiNE Server}"
  record_env_var MAILER_HOST "$MAILER_HOST"
  record_env_var MAILER_PORT "$MAILER_PORT"
  record_env_var MAILER_USER "$MAILER_USER"
  record_env_var MAILER_PASSWORD "$MAILER_PASSWORD"
  record_env_var MAILER_SENDER "$MAILER_SENDER"
  record_env_var MAILER_SERVERNAME "$MAILER_SERVERNAME"
  log "Configured SMTP relay"
}

configure_server_metadata() {
  if [ -n "${CLOUDRON_APP_ORIGIN:-}" ]; then
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
  fi
  export AFFINE_INDEXER_ENABLED=${AFFINE_INDEXER_ENABLED:-false}
  record_env_var AFFINE_SERVER_EXTERNAL_URL "${AFFINE_SERVER_EXTERNAL_URL:-}"
  record_env_var AFFINE_SERVER_HOST "${AFFINE_SERVER_HOST:-}"
  record_env_var AFFINE_SERVER_HTTPS "${AFFINE_SERVER_HTTPS:-}"
  record_env_var AFFINE_INDEXER_ENABLED "$AFFINE_INDEXER_ENABLED"
}

configure_auth() {
  if [ -n "${CLOUDRON_OIDC_CLIENT_ID:-}" ]; then
    export CLOUDRON_OIDC_IDENTIFIER="${CLOUDRON_OIDC_IDENTIFIER:-cloudron}"
    python3 - <<'PY'
import json
import os
from pathlib import Path
config_path = Path(os.environ['APP_DATA_DIR']) / 'config' / 'config.json'
data = json.loads(config_path.read_text())
auth = data.setdefault('auth', {})
providers = auth.setdefault('providers', {})
oidc = providers.setdefault('oidc', {})
oidc['clientId'] = os.environ.get('CLOUDRON_OIDC_CLIENT_ID', '')
oidc['clientSecret'] = os.environ.get('CLOUDRON_OIDC_CLIENT_SECRET', '')
oidc['issuer'] = os.environ.get('CLOUDRON_OIDC_ISSUER') or os.environ.get('CLOUDRON_OIDC_DISCOVERY_URL', '')
args = oidc.setdefault('args', {})
args.setdefault('scope', 'openid profile email')
config_path.write_text(json.dumps(data, indent=2))
PY
    log "Enabled Cloudron OIDC for AFFiNE"
  fi
}

update_server_config() {
  python3 - <<'PY'
import json
import os
from pathlib import Path
from urllib.parse import urlparse
config_path = Path(os.environ['APP_DATA_DIR']) / 'config' / 'config.json'
data = json.loads(config_path.read_text())
server = data.setdefault('server', {})
origin = os.environ.get('CLOUDRON_APP_ORIGIN')
if origin:
    parsed = urlparse(origin)
    server['externalUrl'] = origin
    server['host'] = parsed.hostname or ''
    server['https'] = parsed.scheme == 'https'
config_path.write_text(json.dumps(data, indent=2))
PY
}

main() {
  export HOME="$APP_HOME_DIR"
  prepare_data_dirs
  configure_database
  configure_redis
  configure_mail
  configure_server_metadata
  update_server_config
  configure_auth
  chown -R cloudron:cloudron "$APP_DATA_DIR" "$APP_HOME_DIR"
  log "Starting supervisor"
  exec /usr/bin/supervisord -c "$APP_CODE_DIR/supervisord.conf"
}

main "$@"
