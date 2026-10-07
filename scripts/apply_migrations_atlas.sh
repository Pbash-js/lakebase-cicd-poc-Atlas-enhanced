#!/usr/bin/env bash
# Atlas-native migration apply engine (Community Edition).
# REPLACES scripts/apply_migrations.py + migrations_runner.py + the
# schema_migrations table: the ledger is now atlas_schema_revisions,
# maintained entirely by Atlas. Never write to it by hand (except the
# one-time baseline adoption below, which is the documented path).
#
# Guarantees carried over (now enforced by Atlas):
#   exactly-once via revisions ledger, checksum tamper detection via
#   atlas_schema_revisions + atlas.sum, advisory lock so a second writer
#   physically blocks (we previously relied only on CI serialization).
#
# Usage: apply_migrations_atlas.sh <host> <user> <token>
#   ATLAS_BIN overrides the binary path; ATLAS_MIGRATIONS_DIR the dir.
set -euo pipefail

HOST="${1:?host}"; PGUSER="${2:?user}"; TOKEN="${3:?token}"

cd "$(dirname "$0")/.."
if command -v cygpath >/dev/null 2>&1; then REPO=$(cygpath -m "$(pwd)"); else REPO=$(pwd); fi
ATLAS_BIN="${ATLAS_BIN:-atlas}"
DIR="file://${REPO}/${ATLAS_MIGRATIONS_DIR:-db/migrations}"
ENCODED_USER="$(python -c "import urllib.parse;print(urllib.parse.quote('${PGUSER}', safe=''))")"
URL="postgres://${ENCODED_USER}:${TOKEN}@${HOST}:5432/databricks_postgres?sslmode=require"

HAS_REVISIONS=$(python - "$URL" <<'PYEOF'
import sys, psycopg
with psycopg.connect(sys.argv[1]) as c:
    # Atlas places the ledger in its own dedicated schema (not public).
    n = c.execute("SELECT count(*) FROM information_schema.schemata WHERE schema_name='atlas_schema_revisions'").fetchone()[0]
print("yes" if n else "no")
PYEOF
)

if [ "$HAS_REVISIONS" = "no" ]; then
  # Adoption: DB predates the Atlas ledger. If our legacy schema_migrations
  # table or our app tables exist, everything up to the newest file in the
  # dir is already applied: set the baseline (documented Atlas path) and
  # apply nothing. A truly fresh database just applies from scratch.
  LEGACY=$(python - "$URL" <<'PYEOF'
import sys, psycopg
with psycopg.connect(sys.argv[1]) as c:
    legacy = c.execute("SELECT to_regclass('public.schema_migrations')").fetchone()[0]
    tables = c.execute("SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name IN ('customers','orders','shipments')").fetchone()[0]
print("legacy" if (legacy or tables) else "fresh")
PYEOF
)
  if [ "$LEGACY" = "legacy" ]; then
    BASELINE=$(ls db/migrations | grep -v atlas.sum | sort | tail -1 | cut -d_ -f1)
    echo "▶ adopting pre-Atlas DB: baseline=${BASELINE} (no pending migrations expected)"
    "$ATLAS_BIN" migrate apply --url "$URL" --dir "$DIR" \
      --baseline "$BASELINE"
    exit 0
  fi
fi

"$ATLAS_BIN" migrate apply --url "$URL" --dir "$DIR" --lock-timeout 60s
