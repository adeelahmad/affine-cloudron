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
  export AFFINE_INDEXER_ENABLED="${AFFINE_INDEXER_ENABLED:-true}"
  export AFFINE_INDEXER_SEARCH_PROVIDER="${AFFINE_INDEXER_SEARCH_PROVIDER:-manticoresearch}"
  export AFFINE_INDEXER_SEARCH_ENDPOINT="${AFFINE_INDEXER_SEARCH_ENDPOINT:-http://127.0.0.1:9308}"
}

ensure_runtime_envs() {
  ensure_database_env
  ensure_redis_env
  ensure_mail_env
  ensure_server_env
}

# Helper to parse indexer endpoint into host/port for readiness checks
wait_for_indexer() {
  if [ "${AFFINE_INDEXER_ENABLED:-false}" != "true" ]; then
    return
  fi
  local endpoint="${AFFINE_INDEXER_SEARCH_ENDPOINT:-}"
  if [ -z "$endpoint" ]; then
    return
  fi
  log "Waiting for indexer endpoint ${endpoint}"
  if python3 - "$endpoint" <<'PY'; then
import socket
import sys
import time
from urllib.parse import urlparse

endpoint = sys.argv[1]
if not endpoint.startswith(('http://', 'https://')):
    endpoint = 'http://' + endpoint
parsed = urlparse(endpoint)
host = parsed.hostname
port = parsed.port or (443 if parsed.scheme == 'https' else 80)
if not host or not port:
    sys.exit(1)

for _ in range(60):
    try:
        with socket.create_connection((host, port), timeout=2):
            sys.exit(0)
    except OSError:
        time.sleep(1)
sys.exit(1)
PY
    log "Indexer is ready"
  else
    log "Indexer at ${endpoint} not reachable after waiting, continuing startup"
  fi
}

seed_manticore_tables() {
  local sql_dir="$APP_DIR/manticore"
  if [ ! -d "$sql_dir" ]; then
    return
  fi
  if ! command -v mysql >/dev/null 2>&1; then
    log "mysql client not found; cannot seed Manticore tables"
    return
  fi
  local mysql_cmd=(mysql -h 127.0.0.1 -P 9306)
  for table in doc block; do
    local sql_file="$sql_dir/${table}.sql"
    if [ ! -f "$sql_file" ]; then
      continue
    fi
    if "${mysql_cmd[@]}" < "$sql_file" >/dev/null 2>&1; then
      log "Ensured Manticore table ${table}"
    else
      log "WARNING: Failed to apply ${sql_file} to Manticore"
    fi
  done
}

patch_upload_limits() {
  local target="$APP_DIR/dist/main.js"
  if [ ! -f "$target" ]; then
    return
  fi
  python3 - "$target" <<'PY'
import sys
from pathlib import Path

target = Path(sys.argv[1])
data = target.read_text()
updated = data
updated = updated.replace("limit: 100 * OneMB", "limit: 512 * OneMB", 1)
updated = updated.replace("maxFileSize: 100 * OneMB", "maxFileSize: 512 * OneMB", 1)
if updated != data:
    target.write_text(updated)
PY
}

grant_team_plan_features() {
  log "Ensuring self-hosted workspaces have team plan features"
  node <<'NODE'
const { PrismaClient } = require('@prisma/client');

const prisma = new PrismaClient();

async function main() {
  const feature = await prisma.feature.findFirst({
    where: { name: 'team_plan_v1' },
    orderBy: { deprecatedVersion: 'desc' },
  });
  if (!feature) {
    console.warn('[team-plan] Feature record not found, skipping');
    return;
  }

  const workspaces = await prisma.workspace.findMany({
    select: { id: true },
  });

  for (const { id } of workspaces) {
    const existing = await prisma.workspaceFeature.findFirst({
      where: {
        workspaceId: id,
        name: 'team_plan_v1',
        activated: true,
      },
    });
    if (existing) continue;

    await prisma.workspaceFeature.create({
      data: {
        workspaceId: id,
        featureId: feature.id,
        name: 'team_plan_v1',
        type: feature.deprecatedType ?? 1,
        configs: feature.configs,
        reason: 'selfhost-default',
        activated: true,
      },
    });
    console.log(`[team-plan] Granted team plan to workspace ${id}`);
  }

  await prisma.$executeRawUnsafe(`
    CREATE OR REPLACE FUNCTION grant_team_plan_feature()
    RETURNS TRIGGER AS $$
    DECLARE
      feature_id integer;
      feature_type integer;
      feature_configs jsonb;
    BEGIN
      SELECT id, type, configs
        INTO feature_id, feature_type, feature_configs
      FROM features
      WHERE feature = 'team_plan_v1'
      ORDER BY version DESC
      LIMIT 1;

      IF feature_id IS NULL THEN
        RETURN NEW;
      END IF;

      INSERT INTO workspace_features
        (workspace_id, feature_id, name, type, configs, reason, activated, created_at)
      SELECT
        NEW.id,
        feature_id,
        'team_plan_v1',
        feature_type,
        feature_configs,
        'selfhost-default',
        TRUE,
        NOW()
      WHERE NOT EXISTS (
        SELECT 1 FROM workspace_features
        WHERE workspace_id = NEW.id AND name = 'team_plan_v1' AND activated = TRUE
      );

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
  `);

  await prisma.$executeRawUnsafe(`
    DO $$ BEGIN
      CREATE TRIGGER grant_team_plan_feature_trigger
      AFTER INSERT ON workspaces
      FOR EACH ROW
      EXECUTE FUNCTION grant_team_plan_feature();
    EXCEPTION
      WHEN duplicate_object THEN NULL;
    END $$;
  `);
}

main()
  .then(() => console.log('[team-plan] Workspace quota ensured'))
  .catch(err => {
    console.error('[team-plan] Failed to grant features', err);
  })
  .finally(async () => {
    await prisma.$disconnect();
  });
NODE
}

log "Running AFFiNE pre-deployment migrations"
ensure_runtime_envs
wait_for_indexer
seed_manticore_tables
node ./scripts/self-host-predeploy.js
patch_upload_limits
grant_team_plan_features

log "Starting AFFiNE server"
exec node ./dist/main.js
