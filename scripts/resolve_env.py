#!/usr/bin/env python3
"""Resolve an environment from config/environments.json.

Usage: resolve_env.py <git-branch> [cd|rehearsal]

  cd        branch MUST be a baseline in the config (CD pushes).
  rehearsal base branch selects the environment to fork the rehearsal from;
           non-baseline bases (legacy main, feature bases) fall back to prod.

Secret values are selected by NAME (the config stores secret names, not
values): the caller must export every configured host/token secret as an env
var before invoking this script — EXCEPT in job-output mode (GH_OUTPUTS=1),
which resolves descriptors only and never requires credentials.

Outputs (GitHub Actions):
  GITHUB_ENV    WORKSPACE, LAKEBASE_PROJECT, TARGET_BRANCH
  stdout (only when GH_OUTPUTS=1) deploy_env=..., host_name=..., token_name=...,
           env_name=..., project=..., database=...  for GITHUB_OUTPUT consumption
"""
import fnmatch
import json
import os
import sys


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: resolve_env.py <git-branch> [cd|rehearsal]", file=sys.stderr)
        return 2
    key, mode = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "cd")

    with open("config/environments.json", encoding="utf-8") as f:
        cfg = json.load(f)["environments"]

    match = [name for name, e in cfg.items() if fnmatch.fnmatchcase(key, e["git_branch"])]
    if len(match) > 1:
        print(f"::error::branch '{key}' matches multiple environments in config/environments.json: {', '.join(sorted(match))}", file=sys.stderr)
        return 1
    if match:
        name = match[0]
    elif mode == "rehearsal":
        name = "prod"
        print(f"::notice::base '{key}' is not a baseline in config/environments.json; rehearsal falls back to the prod environment", file=sys.stderr)
    else:
        print(f"::error::branch '{key}' is not a baseline in config/environments.json", file=sys.stderr)
        return 1

    e = cfg[name]
    soft = os.environ.get("GH_OUTPUTS") == "1"
    if not os.environ.get(e["host"]) or not os.environ.get(e["token"]):
        if soft:
            # Job-output mode (cd-promotion resolve): this job only resolves
            # descriptors (deploy_env, secret NAMES, project, database); it
            # holds no Databricks credentials. The deploy job re-resolves the
            # values by name and hard-fails if they are empty.
            print(f"::notice::secrets '{e['host']}'/'{e['token']}' for environment '{name}' not available to this job — descriptor resolution only; the deploy job selects the values by name", file=sys.stderr)
        else:
            print(f"::error::secret '{e['host']}'/'{e['token']}' for environment '{name}' is not available to this workflow", file=sys.stderr)
            return 1

    with open(os.environ.get("GITHUB_ENV", os.devnull), "a", encoding="utf-8") as genv:
        genv.write(f"WORKSPACE={name}\n")
        genv.write(f"LAKEBASE_PROJECT={e['project']}\n")
        genv.write(f"TARGET_BRANCH={e['database']}\n")

    if os.environ.get("GH_OUTPUTS") == "1":
        # plain, non-secret descriptors for GITHUB_OUTPUT (job-level use)
        pairs = [
            ("env_name", name),
            ("deploy_env", e["deploy_env"]),
            ("host_name", e["host"]),
            ("token_name", e["token"]),
            ("project", e["project"]),
            ("database", e["database"]),
        ]
        out_path = os.environ.get("GITHUB_OUTPUT")
        if out_path:
            with open(out_path, "a", encoding="utf-8") as out:
                for k, v in pairs:
                    out.write(f"{k}={v}\n")
        for k, v in pairs:
            print(f"{k}={v}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
