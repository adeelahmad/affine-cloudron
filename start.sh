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
MANTICORE_DATA_DIR=${MANTICORE_DATA_DIR:-$APP_DATA_DIR/manticore}
MANTICORE_CONFIG_FILE=${MANTICORE_CONFIG_FILE:-$MANTICORE_DATA_DIR/manticore.conf}
MANTICORE_HTTP_ENDPOINT=${MANTICORE_HTTP_ENDPOINT:-http://127.0.0.1:9308}
export APP_CODE_DIR APP_DATA_DIR APP_RUNTIME_DIR APP_TMP_DIR APP_BUILD_DIR APP_HOME_DIR AFFINE_HOME ENV_EXPORT_FILE \
  MANTICORE_DATA_DIR MANTICORE_CONFIG_FILE MANTICORE_HTTP_ENDPOINT

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
  mkdir -p /run/nginx/body /run/nginx/proxy /run/nginx/fastcgi /run/nginx/uwsgi /run/nginx/scgi
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

prepare_manticore() {
  log "Preparing Manticore data directory"
  local buddy_plugins_dir="$MANTICORE_DATA_DIR/plugins/buddy-plugins"
  mkdir -p "$MANTICORE_DATA_DIR"/{data,binlog,logs,buddy} "$buddy_plugins_dir"
  cp "$APP_CODE_DIR/manticore/manticore.conf" "$MANTICORE_CONFIG_FILE"
  local composer_file="$buddy_plugins_dir/composer.json"
  if [ ! -f "$composer_file" ]; then
    cat > "$composer_file" <<'JSON'
{
  "require": {},
  "minimum-stability": "dev"
}
JSON
  fi
  local system_buddy_plugins="/usr/share/manticore/modules/manticore-buddy/buddy-plugins"
  if [ ! -L "$system_buddy_plugins" ] && [ -w "/usr/share/manticore/modules/manticore-buddy" ]; then
    rm -rf "$system_buddy_plugins"
    ln -s "$buddy_plugins_dir" "$system_buddy_plugins"
  elif [ ! -L "$system_buddy_plugins" ]; then
    log "Buddy modules directory is read-only; skipping symlink to ${buddy_plugins_dir}"
  fi
  mkdir -p /run/manticore
  chown -R cloudron:cloudron "$MANTICORE_DATA_DIR" /run/manticore
  record_env_var MANTICORE_CONFIG_FILE "$MANTICORE_CONFIG_FILE"
  record_env_var MANTICORE_HTTP_ENDPOINT "$MANTICORE_HTTP_ENDPOINT"
}

prepare_runtime_build_dir() {
  local source_dir="$APP_BUILD_DIR"
  local runtime_build_dir="$APP_RUNTIME_DIR/affine-build"
  log "Syncing AFFiNE runtime into $runtime_build_dir"
  rm -rf "$runtime_build_dir"
  mkdir -p "$runtime_build_dir"
  cp -a "$source_dir/." "$runtime_build_dir/"
  chown -R cloudron:cloudron "$runtime_build_dir"
  APP_BUILD_DIR="$runtime_build_dir"
  export APP_BUILD_DIR
  record_env_var APP_BUILD_DIR "$APP_BUILD_DIR"
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

ensure_pgvector_extension() {
  if [ -z "${DATABASE_URL:-}" ]; then
    log "DATABASE_URL not set; skipping pgvector extension check"
    return
  fi
  if ! command -v psql >/dev/null 2>&1; then
    log "psql client unavailable; cannot verify pgvector extension"
    return
  fi
  log "Ensuring pgvector extension exists"
  if psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS vector;" >/dev/null 2>&1; then
    log "pgvector extension ready"
  else
    log "WARNING: Failed to create pgvector extension automatically. Ensure it exists for AI embeddings."
  fi
}

configure_redis() {
  require_env CLOUDRON_REDIS_URL
  local redis_info
  redis_info=$(python3 - <<'PY'
import os
from urllib.parse import urlparse
url = os.environ.get('CLOUDRON_REDIS_URL')
parsed = urlparse(url) if url else None
host = os.environ.get('CLOUDRON_REDIS_HOST')
port = os.environ.get('CLOUDRON_REDIS_PORT')
password = os.environ.get('CLOUDRON_REDIS_PASSWORD')
username = os.environ.get('CLOUDRON_REDIS_USERNAME')
db = os.environ.get('CLOUDRON_REDIS_DB')
if not host and parsed:
    host = parsed.hostname or 'localhost'
if not port and parsed:
    port = parsed.port or 6379
if not password and parsed:
    password = parsed.password or ''
if not db and parsed:
    db = (parsed.path or '/0').lstrip('/') or '0'
if username is None:
    username = parsed.username if parsed and parsed.username else 'default'
host = host or 'localhost'
port = port or 6379
password = password or ''
db = db or '0'
print(f"{host}\n{port}\n{password}\n{db}\n{username}")
PY
)
  IFS=$'\n' read -r host port password db username <<<"$redis_info"
  if [ -n "${CLOUDRON_REDIS_HOST:-}" ]; then
    host="$CLOUDRON_REDIS_HOST"
  fi
  if [ -n "${CLOUDRON_REDIS_PORT:-}" ]; then
    port="$CLOUDRON_REDIS_PORT"
  fi
  if [ -n "${CLOUDRON_REDIS_PASSWORD:-}" ]; then
    password="$CLOUDRON_REDIS_PASSWORD"
  fi
  if [ -n "${CLOUDRON_REDIS_USERNAME:-}" ]; then
    username="$CLOUDRON_REDIS_USERNAME"
  elif [ -z "$username" ]; then
    username="default"
  fi
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
  local host=""
  local port=""
  local user=""
  local password=""
  local sender=""
  local ignore_tls="false"

  if [ -n "${CLOUDRON_EMAIL_SMTP_SERVER:-}" ]; then
    host="$CLOUDRON_EMAIL_SMTP_SERVER"
    port="${CLOUDRON_EMAIL_SMTPS_PORT:-${CLOUDRON_EMAIL_SMTP_PORT:-587}}"
    user="${CLOUDRON_EMAIL_SMTP_USERNAME:-}"
    password="${CLOUDRON_EMAIL_SMTP_PASSWORD:-}"
    sender="${CLOUDRON_EMAIL_FROM:-AFFiNE <no-reply@cloudron.local>}"
    ignore_tls="${MAILER_IGNORE_TLS:-true}"
    log "Configuring SMTP using Cloudron email addon"
  elif [ -n "${CLOUDRON_MAIL_SMTP_SERVER:-}" ]; then
    host="$CLOUDRON_MAIL_SMTP_SERVER"
    port="${CLOUDRON_MAIL_SMTP_PORT:-587}"
    user="${CLOUDRON_MAIL_SMTP_USERNAME:-}"
    password="${CLOUDRON_MAIL_SMTP_PASSWORD:-}"
    sender="${CLOUDRON_MAIL_FROM:-AFFiNE <no-reply@cloudron.local>}"
    ignore_tls="${MAILER_IGNORE_TLS:-false}"
    if [ -n "${CLOUDRON_MAIL_SMTP_SECURE:-}" ]; then
      case "${CLOUDRON_MAIL_SMTP_SECURE,,}" in
        true|1|yes) port="${CLOUDRON_MAIL_SMTP_PORT:-465}" ;;
      esac
    fi
    log "Configuring SMTP using Cloudron sendmail addon"
  else
    log "Cloudron mail/email addon not configured, skipping SMTP setup"
    return
  fi

  export MAILER_HOST="$host"
  export MAILER_PORT="$port"
  export MAILER_USER="$user"
  export MAILER_PASSWORD="$password"
  export MAILER_SENDER="${sender:-AFFiNE <no-reply@cloudron.local>}"
  export MAILER_SERVERNAME="${MAILER_SERVERNAME:-AFFiNE Server}"
  export MAILER_IGNORE_TLS="$ignore_tls"

  record_env_var MAILER_HOST "$MAILER_HOST"
  record_env_var MAILER_PORT "$MAILER_PORT"
  record_env_var MAILER_USER "$MAILER_USER"
  record_env_var MAILER_PASSWORD "$MAILER_PASSWORD"
  record_env_var MAILER_SENDER "$MAILER_SENDER"
  record_env_var MAILER_SERVERNAME "$MAILER_SERVERNAME"
  record_env_var MAILER_IGNORE_TLS "$MAILER_IGNORE_TLS"
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
  record_env_var AFFINE_SERVER_EXTERNAL_URL "${AFFINE_SERVER_EXTERNAL_URL:-}"
  record_env_var AFFINE_SERVER_HOST "${AFFINE_SERVER_HOST:-}"
  record_env_var AFFINE_SERVER_HTTPS "${AFFINE_SERVER_HTTPS:-}"
}

configure_indexer() {
  export AFFINE_INDEXER_ENABLED=true
  export AFFINE_INDEXER_SEARCH_PROVIDER=${AFFINE_INDEXER_SEARCH_PROVIDER:-manticoresearch}
  export AFFINE_INDEXER_SEARCH_ENDPOINT=${AFFINE_INDEXER_SEARCH_ENDPOINT:-$MANTICORE_HTTP_ENDPOINT}
  record_env_var AFFINE_INDEXER_ENABLED "$AFFINE_INDEXER_ENABLED"
  record_env_var AFFINE_INDEXER_SEARCH_PROVIDER "$AFFINE_INDEXER_SEARCH_PROVIDER"
  record_env_var AFFINE_INDEXER_SEARCH_ENDPOINT "$AFFINE_INDEXER_SEARCH_ENDPOINT"

  python3 - <<'PY'
import json
import os
from pathlib import Path
config_path = Path(os.environ['APP_DATA_DIR']) / 'config' / 'config.json'
data = json.loads(config_path.read_text())
indexer = data.setdefault('indexer', {})
indexer['enabled'] = True
indexer['provider.type'] = os.environ.get('AFFINE_INDEXER_SEARCH_PROVIDER', 'manticoresearch')
indexer['provider.endpoint'] = os.environ.get('AFFINE_INDEXER_SEARCH_ENDPOINT', 'http://127.0.0.1:9308')
config_path.write_text(json.dumps(data, indent=2))
PY
  log "Configured indexer endpoint"
}

configure_auth() {
  if [ -n "${CLOUDRON_OIDC_CLIENT_ID:-}" ]; then
    export CLOUDRON_OIDC_IDENTIFIER="${CLOUDRON_OIDC_IDENTIFIER:-cloudron}"
    python3 - <<'PY'
import json
import os
import re
from pathlib import Path
config_path = Path(os.environ['APP_DATA_DIR']) / 'config' / 'config.json'
data = json.loads(config_path.read_text())
auth = data.setdefault('auth', {})
providers = auth.setdefault('providers', {})
oidc = providers.setdefault('oidc', {})
oidc['clientId'] = os.environ.get('CLOUDRON_OIDC_CLIENT_ID', '')
oidc['clientSecret'] = os.environ.get('CLOUDRON_OIDC_CLIENT_SECRET', '')
issuer = os.environ.get('CLOUDRON_OIDC_ISSUER') or ''
discovery = os.environ.get('CLOUDRON_OIDC_DISCOVERY_URL') or ''
resolved_issuer = issuer
if not resolved_issuer and discovery:
    resolved_issuer = re.sub(r'/\.well-known.*$', '', discovery)
if not resolved_issuer:
    resolved_issuer = discovery
oidc['issuer'] = resolved_issuer
default_scope = os.environ.get('AFFINE_OIDC_SCOPE', 'openid profile email')
default_claims = {
    'claim_id': os.environ.get('AFFINE_OIDC_CLAIM_ID', 'preferred_username'),
    'claim_email': os.environ.get('AFFINE_OIDC_CLAIM_EMAIL', 'email'),
    'claim_name': os.environ.get('AFFINE_OIDC_CLAIM_NAME', 'name'),
}
args = oidc.setdefault('args', {})
args['scope'] = default_scope
for key, value in default_claims.items():
    args.setdefault(key, value)
oauth = data.setdefault('oauth', {})
oauth_providers = oauth.setdefault('providers', {})
oauth_oidc = oauth_providers.setdefault('oidc', {})
oauth_oidc['clientId'] = oidc['clientId']
oauth_oidc['clientSecret'] = oidc['clientSecret']
oauth_oidc['issuer'] = resolved_issuer
oauth_args = oauth_oidc.setdefault('args', {})
oauth_args['scope'] = default_scope
for key, value in default_claims.items():
    oauth_args.setdefault(key, value)
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
  prepare_manticore
  prepare_runtime_build_dir
  configure_database
  ensure_pgvector_extension
  configure_redis
  configure_mail
  configure_server_metadata
  configure_indexer
  update_server_config
  configure_auth
  chown -R cloudron:cloudron "$APP_DATA_DIR" "$APP_HOME_DIR"
  log "Starting supervisor"
  exec /usr/bin/supervisord -c "$APP_CODE_DIR/supervisord.conf"
}

main "$@"
