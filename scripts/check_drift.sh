#!/usr/bin/env bash
# Drift probe: compares the LIVE production branch against Git with ONE
# object-aware `atlas schema diff` (prod vs the full desired state:
# db/schema + db/objects). Covers structural drift, object drift and ghosts
# (live objects missing from the desired state appear as DROPs).
# Exits 1 and prints a drift report when anything differs; exit 0 = no drift.
# Errors (auth, connectivity, diff failure) exit 2 so the caller can tell
# "drift detected" from "probe itself failed".
set -euo pipefail
# Any unexpected command failure (auth expiry, connectivity, bad URL) must
# exit 2 ("probe error"), never 1 ("drift"): the monitor workflow branches on
# the exit code and a wrong code files a false drift issue every day.
trap 'echo "✗ probe error (see report above)" >&2; exit 2' ERR

. "$(dirname "$0")/lib.sh"

: "${LAKEBASE_PROJECT:?set LAKEBASE_PROJECT (the Lakebase project id)}"
: "${DATABRICKS_PG_USER:?set DATABRICKS_PG_USER (the Lakebase Postgres role)}"
SOURCE_BRANCH="${SOURCE_BRANCH:-production}"   # the branch treated as "live"
ATLAS_BIN="${ATLAS_BIN:-atlas}"
command -v "$ATLAS_BIN" >/dev/null 2>&1 || { echo "✗ atlas CLI not found (set ATLAS_BIN)"; exit 2; }
command -v python >/dev/null 2>&1 || { echo "✗ python not found"; exit 2; }

cd "$(dirname "$0")/.."
if command -v cygpath >/dev/null 2>&1; then REPO=$(cygpath -m "$(pwd)"); else REPO=$(pwd); fi

PROD_EP="projects/${LAKEBASE_PROJECT}/branches/${SOURCE_BRANCH}/endpoints/primary"

HOST="$(lb_host "$PROD_EP")"
TOKEN="$(lb_token "$PROD_EP")"
echo "::add-mask::${TOKEN}"   # never leak the runtime credential in logs
ENCODED_USER="$(python -c "import urllib.parse;print(urllib.parse.quote('${DATABRICKS_PG_USER}', safe=''))")"
PROD_URL="postgres://${ENCODED_USER}:***@${HOST}:5432/databricks_postgres?sslmode=require"

SCRATCH="atlas_dev_drift_$$"

cleanup() {
  python - "$PROD_URL" "$SCRATCH" <<'PYEOF'
import sys, psycopg
try:
    with psycopg.connect(sys.argv[1], autocommit=True) as c:
        c.execute(f'DROP DATABASE IF EXISTS "{sys.argv[2]}"')
except Exception as e:
    print(f"cleanup warning: {e}", file=sys.stderr)
PYEOF
}
trap cleanup EXIT

python - "$PROD_URL" "$SCRATCH" <<'PYEOF'
import sys, psycopg
with psycopg.connect(sys.argv[1], autocommit=True) as c:
    c.execute(f'CREATE DATABASE "{sys.argv[2]}" TEMPLATE template0')
PYEOF
DEV_URL="postgres://${ENCODED_USER}:***@${HOST}:5432/${SCRATCH}?sslmode=require"

echo "▶ drift check: object-aware schema diff (prod vs schema.sql + db/objects)"
# Desired state built by scripts/build_desired.py (single source of truth;
# same builder branch_test.sh uses for the declarative deploy). Atlas models
# functions/views/triggers/etc., so one schema diff covers structural AND
# object drift AND ghosts (live objects not in desired state report as DROPs).
python scripts/build_desired.py --out "$REPO/.tmp_pro/desired.sql" >/dev/null
# All declared schemas, not just public: objects moved into auth/authz/
# employee/employee_data were invisible to a hard-coded --schema public
# (lb_schema_args = public + every CREATE SCHEMA in db/schema).
SCHEMA_ARGS=()
while read -r _f _s; do [ -n "${_s:-}" ] && SCHEMA_ARGS+=("$_f" "$_s"); done < <(lb_schema_args)
OUT=$("$ATLAS_BIN" schema diff \
  --from "$PROD_URL" \
  --to "file://${REPO}/.tmp_pro/desired.sql" \
  --dev-url "$DEV_URL" \
  "${SCHEMA_ARGS[@]}" \
  --exclude "public.schema_migrations" \
  --exclude "public.grant_*" 2>&1) || {
  echo "✗ atlas schema diff failed:"; printf '%s\n' "$OUT"; exit 2;
}
# ponytail: platform-owned event triggers (on_create_*) cannot be --exclude'd
# (DB-level resources); filter the known block. Revisit if Lakebase adds more.
# (|| true: an all-noise diff leaves grep with zero output = exit 1.)
OUT="$(printf '%s\n' "$OUT" | grep -vE 'on_create_|DROP EVENT TRIGGER' || true)"
if [ -z "$(printf '%s' "$OUT" | tr -d '[:space:]')" ]; then
  echo "✓ no drift"
  exit 0
fi
echo "✗ drift detected (statements to move prod to desired state):"
printf '%s\n' "$OUT" | sed 's/^/    /'
exit 1
