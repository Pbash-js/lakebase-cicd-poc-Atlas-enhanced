#!/usr/bin/env bash
# Atlas-native migration apply engine (Community Edition).
# The ledger is atlas_schema_revisions, maintained entirely by Atlas. Never
# write to it by hand.
#
# Guarantees: exactly-once via revisions ledger, checksum tamper detection
# via atlas_schema_revisions + atlas.sum, advisory lock so a second writer
# physically blocks, and --tx-mode all so the whole pending batch is ONE
# transaction (a failure halfway leaves nothing applied).
#
# Baseline (adopting a pre-Atlas database) is an EXPLICIT OPERATOR STEP,
# never automatic: a human decides what counts as already-applied and runs
#   ATLAS_BASELINE=<version> ./scripts/apply_migrations_atlas.sh <host> <user> <token>
# where <version> is the newest migration filename prefix in db/migrations/
# (record the decision in the run log / ops doc). Baseline mode applies
# nothing; it only writes the ledger row. A fresh database needs no baseline.
#
# Usage: apply_migrations_atlas.sh <host> <user> <token>
#   ATLAS_BIN overrides the binary path; ATLAS_MIGRATIONS_DIR the dir
#   (repo-relative); ATLAS_BASELINE enables baseline mode (operator step).
set -euo pipefail

HOST="${1:?host}"; PGUSER="${2:?user}"; TOKEN="${3:?token}"

cd "$(dirname "$0")/.."
if command -v cygpath >/dev/null 2>&1; then REPO=$(cygpath -m "$(pwd)"); else REPO=$(pwd); fi
ATLAS_BIN="${ATLAS_BIN:-atlas}"
DIR="file://${REPO}/${ATLAS_MIGRATIONS_DIR:-db/migrations}"
ENCODED_USER="$(python -c "import urllib.parse;print(urllib.parse.quote('${PGUSER}', safe=''))")"
URL="postgres://${ENCODED_USER}:${TOKEN}@${HOST}:5432/databricks_postgres?sslmode=require"

if [ -n "${ATLAS_BASELINE:-}" ]; then
  echo "▶ OPERATOR baseline adoption: baseline=${ATLAS_BASELINE} (nothing applies; ledger row only)"
  "$ATLAS_BIN" migrate apply --url "$URL" --dir "$DIR" --baseline "$ATLAS_BASELINE"
  exit 0
fi

# --tx-mode all: the entire batch applies in ONE transaction, so a failure
# halfway through the pending set leaves NOTHING applied (no half-applied
# migrations). Caveat: DDL that cannot run in a transaction block (e.g.
# CREATE INDEX CONCURRENTLY) is impossible under this mode.
"$ATLAS_BIN" migrate apply --url "$URL" --dir "$DIR" --lock-timeout 60s --tx-mode all
