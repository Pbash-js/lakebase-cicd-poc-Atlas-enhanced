# Lakebase CI/CD

Architecture and design rationale: [docs/DESIGN.md](docs/DESIGN.md). This README is the operating manual.

CI/CD pipeline for Databricks Lakebase Postgres, built on **Atlas Pro**: declarative desired state, official GitHub Actions. CI installs the Pro binary via `ariga/setup-atlas@v0`; every apply lands in the same `atlas_schema_revisions` ledger.

```
SOURCE (Git)                       DEPLOYMENT                                   DATABASE (Lakebase)
db/schema/ (desired state)   ->    LOCAL:  branch_test.sh (Pro declarative      ->  dev-<you> sandbox (7d TTL)
db/objects/ (code SQL)               apply: schema + objects, one tx)             pr-<n> rehearsal (24h, per PR)
db/migrations/ (versioned)   ->    CI:     official Atlas lint + rehearsed      ->  production (on merge, via CD)
                                     apply on pr-<n> (versioned path)             recovery-<run> (pre-deploy PITR)
                             ->    CD:     official migrate/apply to production
```

## The loop: test first, version last

Pro's declarative engine runs the local inner loop. The migration is an artifact frozen only when a change is proven, not a tax on every experiment.

```
1. edit db/schema/*.sql and/or db/objects/**
2. ./scripts/branch_test.sh        # Pro declarative apply converges the dev
                                   # branch to the FULL desired state, one tx.
                                   # No migration needed. Re-run freely.
3. (green) ./scripts/gen_migration.sh <name>   # freeze the versioned artifact
4. commit migration + schema files, open PR    # CI rehearses the MIGRATIONS
5. merge -> CD applies to production (versioned, auditable)
```

Hard rule: CI/CD always run the versioned path (the `GITHUB_ACTIONS` gate). The rehearsal must exercise the migration artifacts, and production is never converged by a declarative diff. Extensions used by code objects are declared in `db/schema/00_extensions.sql` so the declarative diff plans them.

Tell: a local run prints `▶ Pro declarative: schema apply ...`; CI/CD print the versioned steps (`▶ 1/3 migrations`).

## How to read this README / how to use this repo

| You want to... | Do this | Read |
| --- | --- | --- |
| Day-zero setup on a fresh clone | `./scripts/init_project.sh` | [Day zero](#day-zero) |
| Start a change | `feat/*` from `dev`; `hotfix/*` from `prod` | [Branch model](#branch-model) |
| Make a schema change | Edit `db/schema/*.sql`, `branch_test.sh`, then `gen_migration.sh` | [The loop](#the-loop-test-first-version-last) |
| Make a code-object change | Edit the file under `db/objects/<layer>/` | [The loop](#the-loop-test-first-version-last) |
| Rename/drop an object | Add a retirement line (the deploy tells you exactly what) | [Retirements](#retirements-drops-and-signature-changes) |
| Understand what CI blocks | Gates table | [What CI fails on](#what-ci-fails-on-exactly) |
| Configure repo settings | Secrets/variables tables | [GitHub configuration](#github-configuration-settings) |
| Investigate a `schema-drift` issue | Run the probe manually against any branch | [Drift monitor](#drift-monitor-scheduled) |

## Branch model

Four baseline branches map 1:1 to the four workspaces. All changes arrive by PR; baselines never take direct commits.

| Baseline | Workspace | Promote from | Deploy gate |
| --- | --- | --- | --- |
| `dev` (default) | Dev | `feat/*` branches | merge (CI required) |
| `qa` | QA | PR from `dev` | merge (CI required) |
| `release/x.y` | Stage | PR from `qa`, CODEOWNERS | `stage` environment reviewers |
| `prod` | Prod | PR from `release/x.y` | `production` environment reviewers |

Rules: `feat/*` from `dev`; `hotfix/*` from `prod` (the branch whose state production runs); one live `release/x.y` at a time (cut from `qa`, promoted to `prod`, retired on the next cut); hotfixes propagate back down by merge PRs `prod -> release/x.y -> qa -> dev` (the exactly-once ledger makes each apply only what that workspace lacks). The branch -> workspace -> database -> deploy-gate map lives in one file, `config/environments.json`, which every workflow reads; today each environment is a long-lived Lakebase branch in the shared project, and moving to separate workspaces is an edit to that file. Design rationale: [docs/DESIGN.md](docs/DESIGN.md), section 2.

## What each file does

| Path | Role |
| --- | --- |
| `db/schema/*.sql` | Desired state (tables, columns, indexes, FKs, enums, schemas). `schema.sql` loads first; other files append sorted; cross-file FKs must point at objects defined earlier. A `CREATE SCHEMA` in any file makes that schema drift-managed. `00_extensions.sql` declares extensions (planned declaratively under Pro). |
| `db/objects/<layer>/` | Code objects, one file per object, replayed in layer order `01_types` -> `05_triggers`. **Nested folders are supported** (e.g. `03_procedures/Authz/`); the folder is organizational, the SQL names the target schema. Layer numbers are the replay-order convention; the declarative apply plans from the desired state itself. |
| `db/objects/retirements.jsonl` | DROP manifest applied before each replay (`stmt`, `reason`, `requested_in?`). Deleting a file does NOT drop the object; a signature/return-type change cannot replay via `CREATE OR REPLACE` (it silently creates an overload). Both need a line here. Applied lines are recorded in `infra.retirements_applied`, never re-execute, and replays print one quiet summary line (no DROP noise). |
| `db/objects/drift_ignore.jsonl` | Reviewed ignore list for the ghost check (`object`, `reason`). |
| `db/migrations/` + `atlas.sum` | Versioned SQL **generated by Atlas**, never hand-edited. CI immutability gate: a PR may only ADD files here. `atlas.sum` is verified at every apply, so tampering is always visible. |
| `db/tests/smoke/` | Read-only tests, safe against production. Default and CD suite. |
| `db/tests/integration/` | Data-writing tests, PR/dev branches only (`TEST_SUITE=all`). |
| `scripts/init_project.sh` | Single bootstrap. Prompts project id + Postgres role; **offers to create the Lakebase project when missing** (greenfield: `create-project`, then waits for the production endpoint). Writes `.env.local` (gitignored). Greenfield: auto-generates the initial baseline when `db/migrations` is empty and stops with next steps (prod is empty by definition; the baseline ships via PR -> CD). Otherwise probes the **committed baseline** (a clean `git archive HEAD` export) against production: uncommitted WIP never blocks setup, it is reported as a count. |
| `scripts/branch_test.sh` | Deploy entrypoint. Mints a 1-hour credential. **Local**: one declarative apply of the full desired state (schema + objects, one transaction, no migration needed). **CI/CD**: migrations apply -> objects replay. Refuses `TARGET_BRANCH=production` outside GitHub Actions. |
| `scripts/gen_migration.sh` | Creates a dev branch, plans `atlas migrate diff` against a `template0` scratch, writes the migration. Plans `db/schema/*.sql` only; hard-fails a plan containing object DDL (objects ride the replay). `--check` mode: fails when committed migrations do not converge to desired state. |
| `scripts/build_desired.py` | Builds the full Pro desired state (`db/schema/*.sql` + `db/objects` layers, recursive) to one file. Single source of truth for the declarative apply and the Pro drift diff. |
| `scripts/apply_desired.py` | Pro declarative apply: plans with `atlas schema diff` (pure-SQL format), strips Lakebase platform-owned statements (event triggers, see platform facts), executes in ONE transaction. |
| `scripts/apply_objects.py` | Object replay (CI/CD versioned path): layered, one outer transaction, ghost check after commit (extension-owned objects, `deptype='e'`, are never ghosts). |
| `scripts/apply_migrations_atlas.sh` | CI migrations via `atlas migrate apply --tx-mode all` (one transaction for the batch), `atlas migrate validate` first. Baseline adoption is an explicit operator step (`ATLAS_BASELINE=<version>`), never auto-detected. |
| `scripts/check_drift.sh` | Drift probe: one object-aware `atlas schema diff` against the full desired state (structural + object drift + ghosts), no probe branch. Exits 1 on drift, 2 on probe error. |
| `scripts/rollback_migration.sh` | `atlas migrate down` wrapper: reverts the last N migrations with pre-revert data checks. Refuses production (recovery branch instead). |
| `.github/workflows/pr-validation.yml` | Per-PR gates + rehearsal on a fresh `pr-<n>` fork. |
| `.github/workflows/cd-promotion.yml` | On merge: credential mint, recovery fork, official Atlas apply, objects, tests, to production. Serialized, never cancelled. |
| `.github/workflows/schema-drift-monitor.yml` | Daily drift probe; opens/updates a `schema-drift` issue. |

The only Lakebase-specific glue is credential minting (`generate-database-credential`, below) and the DAB bundle; that is the platform's deployment surface, not an Atlas concern.

## Database platform facts (verified live)

- Lakebase Postgres runs **PostgreSQL 17.11**: scratch databases are created from `template0` inside the branch, so Atlas plans against the same engine/version as production.
- No static DB URL exists or should. Pattern: SP OAuth secret (up to 730 days) -> 1-hour workspace token -> 1-hour database credential; username = SP client id = the SP's Postgres role. See [docs/IDENTITIES.md](docs/IDENTITIES.md).
- Lakebase platform-owned objects (`__db_system` schema, `on_create_*`/`on_drop_*` event triggers) are not managed by this repo. Atlas cannot exclude event triggers from plans (verified v1.3.5: `--exclude` does not match them, `atlas.hcl` `skip` blocks are lint-analyzer only), so `apply_desired.py` filters them at execution while Atlas still owns the plan. A schema allowlist (`public` + every declared schema) keeps platform schemas out of every diff.

## Day zero

### Setup (once)

```
git clone https://github.com/Pbash-js/lakebase-cicd-poc-Atlas-enhanced.git
cd lakebase-cicd-poc-Atlas-enhanced
python -m pip install -r requirements.txt     # psycopg, pytest
databricks auth login
./scripts/init_project.sh
```

### `./scripts/init_project.sh`

The single bootstrap, the only command a new clone needs (`branch_test.sh` and `gen_migration.sh` invoke it when `.env.local` is missing; never in CI, which always sets env vars). It:

1. Prompts for the project id and your Postgres role (your Databricks account email); checks CLI auth, starting `databricks auth login` if needed.
2. Offers to **create the project** when it does not exist (id format validated; `create-project` waits for DONE, then waits for the implicit production endpoint).
3. Writes `.env.local` (gitignored): `LAKEBASE_PROJECT`, `DATABRICKS_PG_USER`.
4. Greenfield (empty `db/migrations`): generates the initial baseline from `db/schema` and stops with next steps. Production is empty by definition; it receives the baseline through PR -> CI -> merge -> CD. No drift hoop.
5. Otherwise probes the **committed baseline** against production using a clean `git archive HEAD` export. Uncommitted WIP is invisible to the gate: it is yours to develop on a dev branch (`branch_test.sh` converges it declaratively). Drift here means the committed repo and production disagree; fix one before deploying. The CI Atlas gate rejects the same condition.

### Day one

```
./scripts/branch_test.sh    # creates dev-<you>-<yyyymmdd> off production (7d TTL),
                            # waits for the endpoint, declaratively converges it
                            # to desired state, runs the tests
```

An isolated disposable copy of production. The script refuses `TARGET_BRANCH=production` outside GitHub Actions CD.

Endpoint quota is limited. If a run fails with "exceeded the limit of concurrently active endpoints", reclaim capacity by deleting branches whose work is merged:

```
databricks postgres list-branches "projects/$LAKEBASE_PROJECT" -o json
databricks postgres delete-branch "projects/$LAKEBASE_PROJECT/branches/pr-<n>"
```

Never delete `production`, or a `recovery-<run>` whose CD run has not finished green.

### The daily loop

See [The loop](#the-loop-test-first-version-last). Three change shapes, each a PR:

- **Schema change**: edit `db/schema/*.sql`, `branch_test.sh` until green (declarative, no migration), then `gen_migration.sh`, commit BOTH the migration and the schema files, open the PR. CI verifies the migration converges to the desired state; on drift it FAILS the check and comments the planned SQL (CI never commits).
- **Object change**: edit the object's file under `db/objects/`. Pro local applies it declaratively; it replays idempotently on the next versioned deploy to any branch.
- **Both**: one PR, both files.

### Working from a Databricks workspace

Add the repo as a Git folder (workspace -> Add -> Git folder), edit SQL in the workspace editor, commit and push from the Git folder dialog, then the same PR -> CI -> merge -> CD flow. The database is never edited directly from the workspace.

### Updating an already-deployed object

Edit its `db/objects/` file; the next deploy replays it. If the object exists only inside an old applied migration, ship a NEW migration containing the `CREATE OR REPLACE` AND the matching `db/objects/` file in the same PR. Never edit an applied migration: that is drift, and the pipeline rejects it.

### Retirements: drops and signature changes

`CREATE OR REPLACE` cannot delete an object or change a function's signature/return type (it silently creates an overload). In the same PR:
1. Edit the object file (or delete it).
2. Append one JSON line per drop to `db/objects/retirements.jsonl`, dependents before dependees (e.g. `DROP VIEW` before the function it calls). CASCADE is deliberately not used:

   ```json
   {"stmt": "DROP VIEW IF EXISTS v_order_totals;", "reason": "return type change", "requested_in": "PR#12"}
   ```

3. Replay verifies the result. Each applied statement is recorded in `infra.retirements_applied`; entries already recorded are skipped, so a line never re-executes. Replays print `retirements: 0 executed, N already consumed (no-op)` instead of re-listing the DROPs.
4. The drift probe's definition comparison keeps the result honest afterwards.

If you forget the line, the deploy catches it: the post-replay ghost check fails on the live-but-undeclared object. Locally it offers one-shot cleanup:

```
  ✗ ghost objects: live in public but declared nowhere in db/objects
      sp_mark_shipped (procedure): add {"stmt": "DROP PROCEDURE IF EXISTS sp_mark_shipped;", ...}
  Add DROP statements for these 1 object(s) to db/objects/retirements.jsonl and re-run? [y/N] y
  ✓ appended 1 retirement line(s); re-running deploy
```

CI/CD never prompt: there the ghost list is a hard failure with the exact lines to add. Note Atlas itself does not close this gap (verified v1.3.5: the `-- atlas:renamed_from` directive covers tables/columns/indexes; a function rename plans DROP + CREATE regardless).

### Rollback

No automated undo on production. Two forward-moving paths: a new migration reversing the change (default), or a branch fork / PITR restore for bad data. `rollback_migration.sh` (`atlas migrate down`, pre-revert data checks enforced) exists for dev branches.

## What CI fails on (exactly)

| Gate | Fails when |
| --- | --- |
| Infra-file integrity | PR touches `.github/`, `scripts/` or `databricks.yml` without the `infra-approved` label |
| Migration immutability | PR edits or deletes an existing file in `db/migrations/` (adding new ones is the only allowed change) |
| Atlas lint | parsed analysis of the latest migration fails (destructive, blocking or data-dependent changes); native report on the PR |
| Atlas plan check | committed migrations do not converge to the desired state; the planned SQL is commented on the PR and the check fails (CI never commits: run `./scripts/gen_migration.sh` locally) |
| Atlas apply | `atlas.sum` mismatch (tampered history), or a migration fails against the `pr-<n>` rehearsal |
| Tests | pytest fails on the PR branch (`TEST_SUITE=all`: smoke + integration) |

A label added after a run does not re-fire it. Re-trigger with a fresh event: an empty commit, or close/reopen the PR.

### Rehearsal branch policy

`pr-<n>` is deleted and re-forked off CURRENT production at the start of every validation run (copy-on-write, ~2s). A rehearsal replays exactly what merging today would do, even after production moved. Runs for one PR are serialized by the workflow's concurrency group.

## Drift monitor (scheduled)

`.github/workflows/schema-drift-monitor.yml` runs daily. The probe (`scripts/check_drift.sh`) runs ONE object-aware `atlas schema diff` of the live branch vs the full desired state (`db/schema/*.sql` + `db/objects`, all declared schemas, excluding tooling schemas). It covers structural drift, object drift and ghosts (objects declared nowhere in `db/objects/`, minus `drift_ignore.jsonl`). On drift: fails, and opens/updates a `schema-drift` GitHub issue with the full report. A probe ERROR (auth, connectivity) opens a distinct issue; it is not drift.

This is detection, not managed monitoring: once a day, no changelog/ERD/lineage. Manual run against any branch:

```
LAKEBASE_PROJECT=<id> DATABRICKS_PG_USER=<role> \
SOURCE_BRANCH=<branch> ./scripts/check_drift.sh
```

## GitHub configuration (Settings)

Repository variables (Actions -> Variables):

| Variable | Purpose |
| --- | --- |
| `SP_CI_CLIENT_ID` | SP-CI application ID (PR validation + branch GC; OIDC switchover) |
| `SP_CD_CLIENT_ID` | SP-CD application ID (CD promotion) |
| `SP_MONITOR_CLIENT_ID` | SP-MONITOR application ID (drift monitor) |

Repository secrets:

| Secret | Example |
| --- | --- |
| `DATABRICKS_HOST` | https://dbc-xxxxxxxx.cloud.databricks.com |
| `DATABRICKS_TOKEN` | PAT or SP token with Lakebase access |
| `LAKEBASE_PROJECT` | core-app-db |
| `DATABRICKS_PG_USER` | the Lakebase Postgres role that runs the pipeline |
| `ATLAS_TOKEN` | Atlas Cloud API token for the atlas CLI license check (the CLI session token is NOT accepted, verified live) | portal.ariga.io |

Auth today is the static `DATABRICKS_TOKEN`; the database password is still self-minted per run (below). The OIDC switchover (3 SPs, federation policies, subject strings) is specced in [docs/IDENTITIES.md](docs/IDENTITIES.md); blocked because federation policies are account-level API, beyond Free Edition.

### Pro in CI: official apply + Lakebase credentials

The Pro CD path uses the official `ariga/atlas-action/migrate/apply@v1`. It needs a Postgres URL; Lakebase has no static DB URL. The established pattern (Databricks docs: [external apps via API](https://docs.databricks.com/aws/en/oltp/projects/external-apps-manual-api), [OAuth M2M](https://docs.databricks.com/aws/en/dev-tools/auth/oauth-m2m)):

```
SP OAuth secret (up to 730 days, workspace access on)
  -> M2M client-credentials flow: 1-hour workspace token
  -> generate-database-credential: 1-hour Postgres credential
  -> username = SP client id = that SP's Postgres role
```

The long-lived artifact is the SP secret only. The CD workflow mints the credential in a pre-step and hands the URL to the action. `cd-promotion` accepts a manual dispatch with a rehearsal-branch target to test the apply path without production; manual runs are hard-refused when the target is `production`.

### Alignment with the official Atlas GitHub Actions guide

Source: [atlasgo.io/guides/ci-platforms/github-versioned](https://atlasgo.io/guides/ci-platforms/github-versioned).

| Guide step | This repo | Why |
| --- | --- | --- |
| `ariga/atlas-action/migrate/apply@v1` | `cd-promotion.yml`, against a minted 1-hour credential | no static DB URL |
| Local `docker://postgres` dev-database | Lakebase `template0` scratch inside the branch | same engine/version as production, no Docker |

## Sources

- [Atlas versioned migrations (diff, apply, atlas_schema_revisions)](https://atlasgo.io/versioned/migrations)
- [Atlas pricing (Pro seats, Pipelines, Monitoring)](https://atlasgo.io/pricing)
- [Databricks Docs: Manage branches (TTL model)](https://docs.databricks.com/aws/en/oltp/projects/manage-branches)
- [Databricks Docs: Lakebase authentication (generate-database-credential)](https://docs.databricks.com/aws/en/oltp/projects/authentication)
- [Databricks Blog: Branching databases like code](https://www.databricks.com/blog/branching-databases-code-cicd-pattern-lakebase-production-glaspoort)

## Open items

| # | Change | Open item |
| --- | --- | --- |
| 1 | Ownership | Assign CODEOWNERS to a team instead of individuals; mark the `production` Lakebase branch protected (skipped for this POC by decision) |
| 2 | OIDC credentials | Switch the static `DATABRICKS_TOKEN` to workload federation with the three designated SPs (SP-CI, SP-CD, SP-MONITOR). SPs, Lakebase roles and Postgres grants are DONE (docs/IDENTITIES.md); blocked on federation policies, which need account-level API beyond Free Edition |

Carried from v1, still open: RBAC as code, AI-impact review (AI Gateway), multi-environment promotion with the platform team.
