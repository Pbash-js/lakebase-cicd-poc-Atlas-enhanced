#!/usr/bin/env bash
# Create a personal dev sandbox branch off production (7-day TTL) and wait for
# its endpoint to become ACTIVE. Usage: bash scripts/new_sandbox.sh dev-<you>
set -euo pipefail

BRANCH_ID="${1:?usage: new_sandbox.sh <branch-id>  (lowercase letters, numbers, hyphens)}"
if ! [[ "$BRANCH_ID" =~ ^[a-z][a-z0-9-]{0,62}$ ]]; then
  echo "Invalid branch id '$BRANCH_ID': 1-63 chars, start with a lowercase letter, only lowercase letters/numbers/hyphens" >&2
  exit 1
fi
PROJECT="${LAKEBASE_PROJECT:?set LAKEBASE_PROJECT}"

if databricks postgres get-branch "projects/${PROJECT}/branches/${BRANCH_ID}" -o json >/dev/null 2>&1; then
  echo "Branch ${BRANCH_ID} already exists — reusing"
else
  databricks postgres create-branch "projects/${PROJECT}" "${BRANCH_ID}" \
    --json "{\"spec\":{\"source_branch\":\"projects/${PROJECT}/branches/production\",\"ttl\":\"604800s\"}}" >/dev/null
  echo "Branch ${BRANCH_ID} created (7-day TTL)"
fi

for i in $(seq 1 30); do
  STATE="$(databricks postgres get-endpoint "projects/${PROJECT}/branches/${BRANCH_ID}/endpoints/primary" -o json \
    | python -c "import sys,json;print(json.load(sys.stdin)['status']['current_state'])" 2>/dev/null || true)"
  [ "$STATE" = "ACTIVE" ] && echo "Endpoint ACTIVE" && exit 0
  sleep 2
done
echo "Endpoint did not become ready in time" && exit 1
