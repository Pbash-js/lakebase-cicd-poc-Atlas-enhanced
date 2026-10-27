#!/usr/bin/env bash
# Atlas Pro rollback: revert the last N applied migrations with
# `atlas migrate down` (computes the reverse plan and enforces the
# migrations' pre-revert checks before running it).
#
# CE has no `migrate down`: the CE rollback is the pre-deploy recovery
# branch (forked by cd-promotion before every production apply) or a
# forward migration. This script refuses to run under CE and refuses
# production entirely (branch restore, not SQL undo).
#
# Usage: TARGET_BRANCH=<branch> rollback_migration.sh [amount]   (default 1)
# Requires an authenticated databricks CLI and ATLAS_EDITION=pro.
set -euo pipefail

: "${LAKEBASE_PROJECT:?set LAKEBASE_PROJECT}"
: "${DATABRICKS_PG_USER:?set DATABRICKS_PG_USER}"
TARGET_BRANCH="${TARGET_BRANCH:?set TARGET_BRANCH (never production)}"
AMOUNT="${1:-1}"
ATLAS_BIN="${ATLAS_BIN:-atlas}"

if [ "${ATLAS_EDITION:-ce}" != "pro" ]; then
  echo "✗ atlas migrate down is Pro-only (set ATLAS_EDITION=pro)."
  echo "  CE rollback: restore the pre-deploy recovery branch, or ship a forward migration."
  exit 1
fi
if [ "$TARGET_BRANCH" = "production" ]; then
  echo "✗ refusing to roll back production in place. Restore the recovery branch instead."
  exit 1
fi

command -v "$ATLAS_BIN" >/dev/null 2>&1 || { echo "✗ atlas CLI not found"; exit 2; }
command -v python >/dev/null 2>&1 || { echo "✗ python not found"; exit 2; }
cd "$(dirname "$0")/.."
if command -v cygpath >/dev/null 2>&1; then REPO=$(cygpath -m "$(pwd)"); else REPO=$(pwd); fi

EP="projects/${LAKEBASE_PROJECT}/branches/${TARGET_BRANCH}/endpoints/primary"
HOST="$(databricks postgres get-endpoint "$EP" -o json | python -c "import sys,json;print(json.load(sys.stdin)['status']['hosts']['host'])")"
TOKEN="$(databricks postgres generate-database-credential "$EP" -o json | python -c "import sys,json;print(json.load(sys.stdin)['token'])")"
echo "::add-mask::${TOKEN}"
ENCODED_USER="$(python -c "import urllib.parse;print(urllib.parse.quote('${DATABRICKS_PG_USER}', safe=''))")"
URL="postgres://${ENCODED_USER}:${TOKEN}@${HOST}:5432/databricks_postgres?sslmode=require"

SCRATCH="atlas_down_$$"
SCRURL="postgres://${ENCODED_USER}:${TOKEN}@${HOST}:5432/${SCRATCH}?sslmode=require"
cleanup() {
  python - "$URL" "$SCRATCH" <<'PYEOF'
import sys, psycopg
try:
    with psycopg.connect(sys.argv[1], autocommit=True) as c:
        c.execute(f'DROP DATABASE IF EXISTS "{sys.argv[2]}"')
except Exception as e:
    print(f"cleanup warning: {e}", file=sys.stderr)
PYEOF
}
trap cleanup EXIT
# clean dev DB for the reverse-plan replay (template0; template1 fails the clean check)
python - "$URL" "$SCRATCH" <<'PYEOF'
import sys, psycopg
with psycopg.connect(sys.argv[1], autocommit=True) as c:
    c.execute(f'CREATE DATABASE "{sys.argv[2]}" TEMPLATE template0')
PYEOF

echo "▶ atlas migrate down: reverting ${AMOUNT} migration(s) on ${TARGET_BRANCH}"
"$ATLAS_BIN" migrate down --dir "file://${REPO}/db/migrations" --url "$URL" --dev-url "$SCRURL" "$AMOUNT"
echo "✓ rolled back"
