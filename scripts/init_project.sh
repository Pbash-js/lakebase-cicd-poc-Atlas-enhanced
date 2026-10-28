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
# Local default: Pro declarative inner loop (branch_test converges the branch
# to desired state without a migration). CI/CD ignore this — GITHUB_ACTIONS
# forces the versioned path; 'ce' here restores the migrations-first loop.
export ATLAS_EDITION=pro
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
  echo "✓ initial baseline generated (uncommitted). Not probing: production is"
  echo "  empty by definition and gets the baseline via PR -> merge -> CD."
  echo "  Commit db/migrations + db/schema, open the PR, merge, then re-run init."
  echo "  next: git add db && git commit"
  exit 0
fi

# Baseline sanity: the COMMITTED baseline must match the live Lakebase.
# The probe runs against a clean export of HEAD (git archive), NOT the
# working tree: uncommitted WIP is the developer's business (it converges on
# the dev branch via branch_test) and must never block setup with drift
# noise. Working-tree changes are only counted and reported, informationally.
# Exit code: 0 clean, 1 drift, 2 probe error.
echo "▶ checking committed baseline vs Lakebase (drift probe against production)"
export LAKEBASE_PROJECT="$PROJECT" DATABRICKS_PG_USER="$ROLE"
CLEAN="$(pwd)/.tmp_clean_head"
rm -rf "$CLEAN"; mkdir -p "$CLEAN"
git archive HEAD | tar -x -C "$CLEAN"
WIP=$(git status --porcelain | wc -l | tr -d ' ')
if (cd "$CLEAN" && ./scripts/check_drift.sh); then
  echo "✓ baseline verified: committed repo matches Lakebase"
  [ "$WIP" -gt 0 ] && echo "  ($WIP uncommitted change(s) in your working tree - yours to develop; branch_test converges them on a dev branch)"
  rm -rf "$CLEAN"
else
  rc=$?
  rm -rf "$CLEAN"
  if [ "$rc" = 1 ]; then
    echo "✗ DRIFT between the committed repo and Lakebase - see the report above." >&2
    echo "  Your working tree is NOT the cause (probe ran on a clean HEAD export)." >&2
    echo "  Fix the committed state (or prod) before deploying; the CI Atlas gate will also reject it." >&2
  else
    echo "✗ drift probe itself failed (auth/infra) - investigate before deploying." >&2
  fi
  exit 1
fi
echo "  next: ./scripts/branch_test.sh"
