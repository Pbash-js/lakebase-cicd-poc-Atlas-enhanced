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
echo "  next: ./scripts/branch_test.sh"
