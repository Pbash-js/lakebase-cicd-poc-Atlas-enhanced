# ponytail: shared Lakebase glue extracted from copy-paste across the scripts;
# inline it back if a call site needs custom behavior.
# Source me: . "$(dirname "$0")/lib.sh"

lb_host() { # $1=endpoint path -> prints the endpoint host
  databricks postgres get-endpoint "$1" --output json \
    | python -c "import sys,json;print(json.load(sys.stdin)['status']['hosts']['host'])"
}

lb_token() { # $1=endpoint path -> prints a 1-hour database credential
  databricks postgres generate-database-credential "$1" --output json \
    | python -c "import sys,json;print(json.load(sys.stdin)['token'])"
}

lb_endpoint_state() { # $1=endpoint path -> prints current_state (empty on error)
  databricks postgres get-endpoint "$1" -o json 2>/dev/null \
    | python -c "import sys,json;print(json.load(sys.stdin)['status']['current_state'])" 2>/dev/null || true
}

lb_wait_endpoint() { # $1=endpoint path; returns 0 once ACTIVE or IDLE
  local i state
  for i in $(seq 1 30); do
    state="$(lb_endpoint_state "$1")"
    [ "$state" = "ACTIVE" -o "$state" = "IDLE" ] && return 0
    [ "$i" = 30 ] && return 1
    sleep 2
  done
}

lb_wait_branch_gone() { # $1=branch path; deletes it and waits out the async delete
  databricks postgres delete-branch "$1" >/dev/null 2>&1 || true
  local i
  for i in $(seq 1 15); do
    databricks postgres get-branch "$1" -o json >/dev/null 2>&1 || return 0
    [ "$i" = 15 ] && return 1
    sleep 2
  done
}

lb_create_branch() { # $1=project $2=branch $3=source_branch $4=ttl_seconds
  databricks postgres create-branch "projects/$1" "$2" \
    --json "{\"spec\":{\"source_branch\":\"projects/$1/branches/$3\",\"ttl\":\"$4\"}}" >/dev/null
}
