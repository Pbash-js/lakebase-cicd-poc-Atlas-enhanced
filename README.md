# Lakebase CI/CD POC — GitHub Actions + Cookbook Runner

POC implementation of the *Databricks Lakebase CI/CD Architecture Playbook v6*
(Cookbook-native migrations, no Flyway). Targets Databricks Free Edition.

## Repo layout
- `db/migrations/` — stateful, run-once plain SQL (`NNN_description.sql`), applied exactly-once by `scripts/apply_migrations.py` (Cookbook `migrations_runner.py`), tracked in `schema_migrations` with SHA-256 checksums. Editing an applied file = DRIFT, pipeline fails.
- `db/objects/` — stateless one-file-per-object SQL, re-applied idempotently (CREATE OR REPLACE) in layer order 01_types -> 02_functions -> 03_procedures -> 04_views -> 05_triggers.
- `db/tests/` — pytest suite run against the PR branch.
- `scripts/` — runner + deploy entrypoint (mints a 60-min OAuth DB credential per invocation).
- `.github/workflows/` — pr-validation.yml (ephemeral TTL branch per PR), cd-promotion.yml (replay to production on merge), cleanup-orphans.yml (weekly GC).

## Local loop
```
databricks auth login --profile free-edition
./scripts/deploy_db.sh                      # TARGET_BRANCH env, defaults to production
TARGET_BRANCH=dev-<you> ./scripts/deploy_db.sh
pytest db/tests -q
```

## GitHub secrets required (Settings -> Secrets and variables -> Actions)
| Secret | Example |
| --- | --- |
| DATABRICKS_HOST | https://dbc-xxxxxxxx.cloud.databricks.com |
| DATABRICKS_TOKEN | PAT (POC) or SP OAuth secret |
| LAKEBASE_PROJECT | core-app-db |
| DATABRICKS_PG_USER | your Lakebase Postgres role (user email or SP client id) |
