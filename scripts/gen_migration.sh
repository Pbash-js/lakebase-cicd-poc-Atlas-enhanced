#!/usr/bin/env bash
# Wraps Atlas Community Edition `atlas migrate diff` against a scratch
# database inside the target Lakebase branch. Desired state is a single
# declarative SQL: db/schema/ (schema.sql is the base file; every other
# *.sql in the dir is appended after it, sorted - cross-file FKs must point at
# objects defined earlier). Atlas plans; Atlas-native
# apply (scripts/apply_migrations_atlas.sh) applies. Atlas never writes
# to the application schema, and the live database is never diffed.
#
# The dev database gets WIPED on every diff (Atlas rebuilds it), so it must
# never be the branch's application database: we create a throwaway
# `atlas_dev_<pid>` database from template0 (template1 carries __db_system
# objects that fail Atlas's clean-dev check) and drop it afterwards.
#
# Usage: gen_migration.sh [name] [--check]
#   [name]     migration label (default: atlas_generated)
#   --check    do not write; run the diff in a throwaway copy of
#              db/migrations and FAIL if Atlas would generate a new file.
#
# Interactive default (no env): prompts for a dev branch name (default
# dev-<user>-<date>), creates it off production with a 1-day TTL if missing,
# runs the diff, and leaves the generated file in db/migrations to commit.
# CI sets TARGET_BRANCH or PR_ID. databricks CLI must be authenticated
# (CI: DATABRICKS_HOST + DATABRICKS_TOKEN; local: auth login).
# LAKEBASE_PROJECT is required (prompted interactively, hard-failed in CI).
set -euo pipefail

NAME="atlas_generated"
CHECK=0
for a in "$@"; do
  case "$a" in
    --check) CHECK=1 ;;
    *) NAME="$a" ;;
  esac
done


# Desired state = db/schema/*.sql in a fixed order: schema.sql first (the
# base), then the rest sorted. A single hard-coded schema.sql would silently
# ignore every other file in db/schema (verified bug: AMSShared.sql invisible).
build_desired() {
  _out="$1"
  { cat "db/schema/schema.sql"; find db/schema -name '*.sql' ! -name 'schema.sql' -type f | LC_ALL=C sort | xargs -r cat; } > "$_out"
  [ -s "$_out" ] || { echo "✗ db/schema is empty" >&2; exit 2; }
}

INTERACTIVE=0
[ -t 0 ] && INTERACTIVE=1

if [ -n "${TARGET_BRANCH:-}" ]; then
  BRANCH="$TARGET_BRANCH"
elif [ -n "${PR_ID:-}" ]; then
  BRANCH="pr-${PR_ID}"
else
  _DEFAULT="dev-$(whoami | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9' | cut -c1-12)-$(date +%Y%m%d)"
  read -r -p "Dev branch name [${_DEFAULT}]: " _TB || _TB=""
  BRANCH="${_TB:-$_DEFAULT}"
fi

[ -f ".env.local" ] && . ".env.local"
if [ -z "${LAKEBASE_PROJECT:-}" ] && [ ! -f ".env.local" ]; then
  echo "▶ first run - one-time setup:"
  ./scripts/init_project.sh
  . ".env.local"
fi
if [ -z "${LAKEBASE_PROJECT:-}" ]; then
  if [ "$INTERACTIVE" = 1 ]; then
    read -r -p "Lakebase project id: " LAKEBASE_PROJECT
  fi
  : "${LAKEBASE_PROJECT:?set LAKEBASE_PROJECT}"
fi
if [ -z "${DATABRICKS_PG_USER:-}" ] && [ "$INTERACTIVE" = 1 ]; then
  read -r -p "Lakebase Postgres role: " DATABRICKS_PG_USER
fi

ATLAS_BIN="${ATLAS_BIN:-atlas}"
command -v "$ATLAS_BIN" >/dev/null 2>&1 || { echo "✗ atlas CLI not found (set ATLAS_BIN)"; exit 1; }
command -v python >/dev/null 2>&1 || { echo "✗ python not found"; exit 1; }

ENDPOINT="projects/${LAKEBASE_PROJECT}/branches/${BRANCH}/endpoints/primary"

# Dev branches are created on demand (1-day TTL) so the loop stays one command.
if [ -n "${TARGET_BRANCH:-}" ] || [ -n "${PR_ID:-}" ]; then
  : # CI provisions its own branches
elif ! databricks postgres get-branch "projects/${LAKEBASE_PROJECT}/branches/${BRANCH}" -o json >/dev/null 2>&1; then
  echo "▶ creating dev branch ${BRANCH} off production (1-day TTL)"
  databricks postgres create-branch "projects/${LAKEBASE_PROJECT}" "${BRANCH}" \
    --json "{\"spec\":{\"source_branch\":\"projects/${LAKEBASE_PROJECT}/branches/production\",\"ttl\":\"86400s\"}}" >/dev/null
fi

echo "▶ atlas plan: branch=${BRANCH} project=${LAKEBASE_PROJECT}"

HOST="$(databricks postgres get-endpoint "$ENDPOINT" --output json \
  | python -c "import sys,json;print(json.load(sys.stdin)['status']['hosts']['host'])")"
TOKEN="$(databricks postgres generate-database-credential "$ENDPOINT" --output json \
  | python -c "import sys,json;print(json.load(sys.stdin)['token'])")"

SCRATCH="atlas_dev_$$"
DEV_URL="postgres://$(python -c "import urllib.parse;print(urllib.parse.quote('${DATABRICKS_PG_USER:?}', safe=''))"):${TOKEN}@${HOST}:5432/${SCRATCH}?sslmode=require"
APP_URL="postgres://$(python -c "import urllib.parse;print(urllib.parse.quote('${DATABRICKS_PG_USER}', safe=''))"):${TOKEN}@${HOST}:5432/databricks_postgres?sslmode=require"

cleanup() {
  python - "$APP_URL" "$SCRATCH" <<'PYEOF'
import sys, psycopg
try:
    with psycopg.connect(sys.argv[1], autocommit=True) as c:
        c.execute(f'DROP DATABASE IF EXISTS "{sys.argv[2]}"')
except Exception as e:
    print(f"cleanup warning: {e}", file=sys.stderr)
PYEOF
}
trap cleanup EXIT

# Scratch database from template0, outside any transaction.
python - "$APP_URL" "$SCRATCH" <<'PYEOF'
import sys, psycopg
with psycopg.connect(sys.argv[1], autocommit=True) as c:
    c.execute(f'CREATE DATABASE "{sys.argv[2]}" TEMPLATE template0')
print("▶ scratch dev database created (template0)")
PYEOF
DEV_URL="postgres://$(python -c "import urllib.parse;print(urllib.parse.quote('${DATABRICKS_PG_USER}', safe=''))"):${TOKEN}@${HOST}:5432/${SCRATCH}?sslmode=require"

cd "$(dirname "$0")/.."
# Windows git-bash: give Atlas a native path it can resolve.
if command -v cygpath >/dev/null 2>&1; then REPO=$(cygpath -m "$(pwd)"); else REPO=$(pwd); fi

if [ "$CHECK" = 1 ]; then
  # Plan into a throwaway copy: a NEW file means the committed migrations
  # do not converge to the desired state — fail the PR.
  # desired.sql must NOT sit in the migrations copy dir: atlas.sum would read
  # it as a foreign file ("checksum mismatch").
  TMPD="$(mktemp -d)"; MIG="$TMPD/mig"; mkdir "$MIG"
  DESIRED="$TMPD/desired.sql"
  build_desired "$DESIRED"                      # bash writes via the MSYS path
  cp db/migrations/*.sql db/migrations/atlas.sum "$MIG"/ 2>/dev/null || true
  if command -v cygpath >/dev/null 2>&1; then   # Atlas needs native paths in URLs
    TMPD=$(cygpath -m "$TMPD"); MIG=$(cygpath -m "$MIG"); DESIRED=$(cygpath -m "$DESIRED")
  fi
  "$ATLAS_BIN" migrate diff "$NAME" \
    --dir "file://${MIG}" \
    --to "file://${DESIRED}" \
    --dev-url "$DEV_URL" >/dev/null \
  || { echo "::error::plan check failed on an Atlas/infra error (not drift) - see log above"; exit 2; }
  BASE=$(ls db/migrations | grep -v atlas.sum | sort | tail -1)
  NEW=$(ls "$MIG" | grep -v atlas.sum | sort | tail -1)
  if grep -qiE 'DROP (VIEW|FUNCTION|PROCEDURE|TRIGGER) ' "$MIG/$NEW"; then
  echo "::error::plan wants to drop code objects - objects deploy via the replay (db/objects), never via migrations. The scratch dev DB was polluted or objects are missing from the desired state; do NOT commit this plan. See README Object changes."
  cat "$MIG/$NEW"
  exit 2
  fi
  if [ "$NEW" != "$BASE" ]; then
    echo "::error::desired state (db/schema) drifted from db/migrations — CI never commits: run gen_migration.sh locally and commit both files"
    echo "--- Atlas would generate: ---"
    cat "$MIG/$NEW"
    exit 1
  fi
  echo "✓ plan check clean: db/migrations matches db/schema"
  # Pro mode: the plan check doubles as the lint gate (migrate lint is
  # Pro-only; it replays the dir on the same scratch dev DB and parses the
  # SQL for destructive / blocking / data-dependent changes).
  if [ "${ATLAS_EDITION:-ce}" = "pro" ]; then
    echo "▶ atlas lint (Pro): analyzing the latest migrations"
    "$ATLAS_BIN" migrate lint --latest 1 \
      --dir "file://${REPO}/db/migrations" \
      --dev-url "$DEV_URL" \
    || { echo "::error::atlas lint failed on an infra error (not drift) - see log above"; exit 2; }
    echo "✓ lint clean"
  fi
else
  TMPD="$(mktemp -d)"
  DESIRED="$TMPD/desired.sql"
  build_desired "$DESIRED"
  if command -v cygpath >/dev/null 2>&1; then DESIRED=$(cygpath -m "$DESIRED"); fi
  "$ATLAS_BIN" migrate diff "$NAME" \
    --dir "file://${REPO}/db/migrations" \
    --to "file://${DESIRED}" \
    --dev-url "$DEV_URL"
  # Normalize to LF and re-hash: atlas.sum must match the git BLOBS, not a
  # Windows CRLF working tree (autocrlf checkouts would break CI verification).
  find db/migrations -name '*.sql' -exec sed -i 's/\r$//' {} +
  "$ATLAS_BIN" migrate hash --dir "file://${REPO}/db/migrations"
  NEWEST="$(ls db/migrations | grep -v atlas.sum | sort | tail -1)"
  if grep -qiE 'DROP (VIEW|FUNCTION|PROCEDURE|TRIGGER) ' "db/migrations/$NEWEST"; then
    echo "✗ generated plan drops code objects - objects deploy via the replay (db/objects), never via migrations (see README Object changes)."
    echo "  The scratch dev DB was polluted or objects are missing from the desired state. NOT staging anything."
    git checkout -- db/migrations/atlas.sum 2>/dev/null || true
    rm -f "db/migrations/$NEWEST"
    exit 2
  fi
  # auto-stage so a generated migration can never be left untracked
  git add db/migrations
  echo "✓ generated (staged): $NEWEST"
  echo "  commit it with the schema edit: git add db && git commit"
fi
