#!/bin/bash
set -euo pipefail

MANTICORE_CONF=${MANTICORE_CONF:-/app/data/manticore/manticore.conf}
MANTICORE_RUN_DIR=${MANTICORE_RUN_DIR:-/run/manticore}

mkdir -p "$MANTICORE_RUN_DIR"
rm -f "$MANTICORE_RUN_DIR/searchd.pid"

exec /usr/bin/searchd --nodetach -c "$MANTICORE_CONF"
