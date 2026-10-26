#!/usr/bin/env bash
# Drift probe: compares the LIVE production branch against Git (items the
# CE pipeline otherwise cannot see).
#   5a structural : atlas schema diff --from <prod> --to db/schema/schema.sql
#                   (tables, columns, indexes, constraints, enums)
#   5b objects    : fork production into a short-lived probe branch, replay
#                   db/objects there, then compare pg_get_functiondef /
#                   pg_get_viewdef / pg_get_triggerdef between prod and the
#                   probe. Both sides run the same Postgres version, so the
#                   definitions compare textually without normalization glue.
# Exits 1 and prints a drift report when anything differs; exit 0 = no drift.
# Errors (auth, connectivity, replay failure) exit 2 so the caller can tell
# "drift detected" from "probe itself failed".
set -euo pipefail

: "${LAKEBASE_PROJECT:?set LAKEBASE_PROJECT (the Lakebase project id)}"
: "${DATABRICKS_PG_USER:?set DATABRICKS_PG_USER (the Lakebase Postgres role)}"
SOURCE_BRANCH="${SOURCE_BRANCH:-production}"   # the branch treated as "live"
PROBE_BRANCH="${PROBE_BRANCH:-drift-probe}"
ATLAS_BIN="${ATLAS_BIN:-atlas}"
command -v "$ATLAS_BIN" >/dev/null 2>&1 || { echo "✗ atlas CLI not found (set ATLAS_BIN)"; exit 2; }
command -v python >/dev/null 2>&1 || { echo "✗ python not found"; exit 2; }

cd "$(dirname "$0")/.."
if command -v cygpath >/dev/null 2>&1; then REPO=$(cygpath -m "$(pwd)"); else REPO=$(pwd); fi

PROD_EP="projects/${LAKEBASE_PROJECT}/branches/${SOURCE_BRANCH}/endpoints/primary"
PROBE_PATH="projects/${LAKEBASE_PROJECT}/branches/${PROBE_BRANCH}"
PROBE_EP="${PROBE_PATH}/endpoints/primary"

HOST="$(databricks postgres get-endpoint "$PROD_EP" --output json \
  | python -c "import sys,json;print(json.load(sys.stdin)['status']['hosts']['host'])")"
TOKEN="$(databricks postgres generate-database-credential "$PROD_EP" --output json \
  | python -c "import sys,json;print(json.load(sys.stdin)['token'])")"
ENCODED_USER="$(python -c "import urllib.parse;print(urllib.parse.quote('${DATABRICKS_PG_USER}', safe=''))")"
PROD_URL="postgres://${ENCODED_USER}:${TOKEN}@${HOST}:5432/databricks_postgres?sslmode=require"

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
  databricks postgres delete-branch "$PROBE_PATH" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# --- 5a: structural drift (atlas schema diff) --------------------------------
python - "$PROD_URL" "$SCRATCH" <<'PYEOF'
import sys, psycopg
with psycopg.connect(sys.argv[1], autocommit=True) as c:
    c.execute(f'CREATE DATABASE "{sys.argv[2]}" TEMPLATE template0')
PYEOF
DEV_URL="postgres://${ENCODED_USER}:${TOKEN}@${HOST}:5432/${SCRATCH}?sslmode=require"

echo "▶ 5a structural drift: prod vs db/schema/schema.sql"
# -s public + excludes: tooling metadata (Lakebase __db_system, the Atlas
# ledger schema, the legacy pre-Atlas schema_migrations table) is not app
# schema and must not read as drift.
STRUCT_OUT="$("$ATLAS_BIN" schema diff \
  --from "$PROD_URL" \
  --to "file://${REPO}/db/schema/schema.sql" \
  --dev-url "$DEV_URL" \
  --schema public \
  --exclude "public.schema_migrations" 2>&1)" || {
  echo "✗ atlas schema diff failed:"; printf '%s\n' "$STRUCT_OUT"; exit 2;
}
STRUCT_DRIFT=0
if printf '%s\n' "$STRUCT_OUT" | grep -qi 'schemas are synced'; then
  echo "  clean: no structural drift"
else
  STRUCT_DRIFT=1
  echo "  DRIFT DETECTED (statements to move prod to desired state):"
  printf '%s\n' "$STRUCT_OUT" | sed 's/^/    /'
fi

# --- 5b: object drift (probe branch + def comparison) ------------------------
echo "▶ 5b object drift: prod vs db/objects replay"
databricks postgres delete-branch "$PROBE_PATH" >/dev/null 2>&1 || true
for i in $(seq 1 15); do   # deletion is async; wait until it is gone
  databricks postgres get-branch "$PROBE_PATH" -o json >/dev/null 2>&1 || break
  [ "$i" = 15 ] && { echo "✗ stale ${PROBE_BRANCH} did not delete in time" >&2; exit 2; }
  sleep 2
done
databricks postgres create-branch "projects/${LAKEBASE_PROJECT}" "$PROBE_BRANCH" \
  --json "{\"spec\":{\"source_branch\":\"projects/${LAKEBASE_PROJECT}/branches/${SOURCE_BRANCH}\",\"ttl\":\"86400s\"}}" >/dev/null
for i in $(seq 1 30); do
  STATE="$(databricks postgres get-endpoint "$PROBE_EP" -o json \
    | python -c "import sys,json;print(json.load(sys.stdin)['status']['current_state'])" 2>/dev/null || true)"
  [ "$STATE" = "ACTIVE" -o "$STATE" = "IDLE" ] && break
  [ "$i" = 30 ] && { echo "✗ probe endpoint not ready" >&2; exit 2; }
  sleep 2
done
PROBE_HOST="$(databricks postgres get-endpoint "$PROBE_EP" --output json \
  | python -c "import sys,json;print(json.load(sys.stdin)['status']['hosts']['host'])")"
PROBE_TOKEN="$(databricks postgres generate-database-credential "$PROBE_EP" --output json \
  | python -c "import sys,json;print(json.load(sys.stdin)['token'])")"

python scripts/apply_objects.py \
  --host "$PROBE_HOST" --port 5432 --dbname databricks_postgres \
  --user "${DATABRICKS_PG_USER}" --password "$PROBE_TOKEN" \
  --sslmode require --objects-root db/objects >/dev/null || {
  echo "✗ object replay on the probe branch failed (repo objects do not apply cleanly)" >&2; exit 2;
}

PROBE_URL="postgres://${ENCODED_USER}:${PROBE_TOKEN}@${PROBE_HOST}:5432/databricks_postgres?sslmode=require"
DEF_DIFF="$(python - "$PROD_URL" "$PROBE_URL" "$REPO" <<'PYEOF'
import sys, re, difflib, psycopg
from pathlib import Path

# Objects owned by extensions (databricks_auth etc.) are not ours to police.
DEFS_SQL = """
SELECT 'function', pg_get_functiondef(p.oid), p.proname::text
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.prokind = 'f'
   AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
UNION ALL
SELECT 'view', pg_get_viewdef(c.oid, true), c.relname::text
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE c.relkind = 'v' AND n.nspname = 'public'
   AND NOT EXISTS (
     SELECT 1 FROM pg_rewrite r JOIN pg_depend d
       ON d.objid = r.oid AND d.classid = 'pg_rewrite'::regclass
      WHERE r.ev_class = c.oid AND d.deptype = 'e')
UNION ALL
SELECT 'trigger', pg_get_triggerdef(t.oid), t.tgname::text
  FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
   JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE NOT t.tgisinternal AND n.nspname = 'public'
   AND NOT EXISTS (SELECT 1 FROM pg_depend d
                    WHERE d.objid = t.oid AND d.classid = 'pg_trigger'::regclass AND d.deptype = 'e')
"""

def dump(url):
    with psycopg.connect(url) as c:
        rows = c.execute(DEFS_SQL).fetchall()
    lines = sorted(f"{k}|{' '.join(d.split())}" for k, d, n in rows if d)
    names = {(k, n.lower()) for k, d, n in rows if d}
    return lines, names

# Names the repo declares anywhere under db/objects/
repo = Path(sys.argv[3])
declared = set()
for f in repo.glob("db/objects/**/*.sql"):
    for m in re.finditer(
        r"(?is)CREATE\s+(?:OR\s+REPLACE\s+)?(?:FUNCTION|VIEW|TRIGGER)\s+(?:public\.)?([A-Za-z_][\w]*)",
        f.read_text(encoding="utf-8"),
    ):
        declared.add(m.group(1).lower())

# Reviewed ignore list: names on production that are managed outside
# db/objects (e.g. legacy rbac helpers) and must not read as ghosts.
ig = repo / "db/objects/drift_ignore.txt"
if ig.is_file():
    for raw in ig.read_text(encoding="utf-8").splitlines():
        line = raw.strip().lower()
        if line and not line.startswith("#"):
            declared.add(line)

prod_lines, prod_names = dump(sys.argv[1])
probe_lines, _ = dump(sys.argv[2])

out, drift = [], 0
diff = list(difflib.unified_diff(prod_lines, probe_lines, "production", "git-replay", lineterm=""))
if diff:
    drift = 1
    out.append("definition mismatch (production | git-replay; '-'=prod, '+'=repo replay):")
    out += diff
ghosts = sorted(f"{k}: {n}" for k, n in prod_names if n not in declared)
if ghosts:
    drift = 1
    out.append("ghost objects on production, declared nowhere in db/objects:")
    out += [f"  {g}" for g in ghosts]
if drift:
    print("\n".join(out))
    sys.exit(1)
PYEOF
)" && OBJ_DRIFT=0 || OBJ_DRIFT=$?

if [ "$OBJ_DRIFT" = 0 ]; then
  echo "  clean: prod object definitions match the repo replay"
else
  echo "  DRIFT DETECTED (production | git-replay; '-'=prod-only, '+'=what the repo objects produce):"
  printf '%s\n' "$DEF_DIFF" | sed 's/^/    /'
fi

[ "$STRUCT_DRIFT" = 0 ] && [ "$OBJ_DRIFT" = 0 ] && { echo "✓ no drift"; exit 0; }
echo "✗ drift detected (structural=$STRUCT_DRIFT objects=$OBJ_DRIFT)"
exit 1
