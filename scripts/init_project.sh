#!/usr/bin/env bash
# One-time setup: writes .env.local (project id + Postgres role) and checks auth.
# Re-run any time; branch_test.sh sources .env.local automatically.
set -euo pipefail
cd "$(dirname "$0")/.."

read -r -p "Lakebase project id [core-app-db]: " P
PROJECT="${P:-core-app-db}"
read -r -p "Lakebase Postgres role (your email): " ROLE
[ -n "$ROLE" ] || { echo "✗ role required"; exit 1; }

if databricks current-user me -o json >/dev/null 2>&1; then
  echo "✓ Databricks CLI authenticated"
else
  echo "▶ not authenticated — starting databricks auth login (browser)"
  databricks auth login
  databricks current-user me -o json >/dev/null || { echo "✗ auth failed"; exit 1; }
fi

cat > .env.local <<EOF
export LAKEBASE_PROJECT="$PROJECT"
export DATABRICKS_PG_USER="$ROLE"
EOF
grep -q "^\.env.local$" .gitignore 2>/dev/null || echo ".env.local" >> .gitignore
echo "✓ wrote .env.local (LAKEBASE_PROJECT=$PROJECT, DATABRICKS_PG_USER=$ROLE)"

. scripts/lib.sh

# Greenfield: the project (and its implicit production branch + primary
# endpoint) may not exist yet. Create it here so gen_migration (forks off
# production) and the drift probe (reads production) work immediately after.
if ! databricks postgres get-project "projects/$PROJECT" -o json >/dev/null 2>&1; then
  if ! echo "$PROJECT" | grep -qE '^[a-z][a-z0-9-]{0,62}$'; then
    echo "✗ project id '$PROJECT' invalid: 1-63 chars, lowercase letters/numbers/hyphens, start with a letter"
    exit 1
  fi
  read -r -p "Project '$PROJECT' does not exist. Create it now? [Y/n] " ANS
  if [ "${ANS:-y}" = "y" ] || [ "${ANS:-Y}" = "Y" ]; then
    echo "▶ creating project $PROJECT (long-running; waits for DONE)"
    databricks postgres create-project "$PROJECT" >/dev/null
    echo "▶ waiting for the production endpoint to become ready"
    lb_wait_endpoint "projects/$PROJECT/branches/production/endpoints/primary" \
      || { echo "✗ production endpoint did not become ready in time"; exit 1; }
    echo "✓ project ready (production branch + primary endpoint provisioned)"
  else
    echo "✗ cannot continue without the project - create it (CLI/console) and re-run."
    exit 1
  fi
fi

# Greenfield: no migrations yet -> generate the initial baseline from the
# desired state (db/schema). Then the drift probe below is meaningful.
if ! ls db/migrations/*.sql >/dev/null 2>&1; then
  echo "▶ greenfield: db/migrations is empty - generating initial baseline"
  ./scripts/gen_migration.sh initial
fi

# Baseline sanity: the repo's declared state must match the live Lakebase
# (inherent drift detection, independent of the CI Atlas check). Read-only
# probe against production; failures here mean fix the repo or the DB BEFORE
# any deploy. Exit code: 0 clean, 1 drift, 2 probe error.
echo "▶ checking repo vs Lakebase (drift probe against production)"
export LAKEBASE_PROJECT="$PROJECT" DATABRICKS_PG_USER="$ROLE"
if ./scripts/check_drift.sh; then
  echo "✓ baseline verified: repo matches Lakebase"
else
  rc=$?
  if [ "$rc" = 1 ]; then
    echo "✗ DRIFT between this repo and Lakebase - see the report above." >&2
    echo "  Do not deploy until resolved (the CI Atlas gate will also reject it)." >&2
  else
    echo "✗ drift probe itself failed (auth/infra) - investigate before deploying." >&2
  fi
  exit 1
fi
echo "  next: ./scripts/branch_test.sh"
