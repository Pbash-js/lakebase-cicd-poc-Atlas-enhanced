# Lakebase CI/CD: dual-engine migrator (Atlas Pro primary, CE fallback)

Architecture and design rationale: [docs/DESIGN.md](docs/DESIGN.md). This README is the operating manual.

Migration pipeline for Lakebase Postgres with two switchable engines:

- **Atlas Pro track (default target architecture)**: the official Atlas
  GitHub Actions do the work: `setup-atlas`, `migrate/lint` on every PR,
  `migrate/push` to the Schema Registry on merge, and `migrate/apply` to the
  database. Atlas owns planning, linting, versioning and deployment; this
  repo provides the desired state, the Lakebase topology and the credential
  plumbing.
- **Atlas CE track (fallback, and the plan-check engine under Pro)**: the same repo mechanics
  with verified repo code closing every CE gap (transactional applies,
  trigger recreation, retirement manifest, destructive gate, drift probe).

The engine is one runtime setting: `ATLAS_EDITION=pro|ce` (see
[Atlas edition switch](#atlas-edition-switch-ce--pro)). One binary, no fork:
a migration applied by either track lands in the same
`atlas_schema_revisions` ledger. GitHub Actions runs CI on every PR and CD
on merge.

```
SOURCE (Git)                DEPLOYMENT                                        DATABASE (Lakebase)
db/schema/schema.sql   ->   PRO:   setup-atlas · migrate/lint · migrate/push  ->  pr-<n> rehearsal (fresh fork every run)
db/objects/ (code SQL)        + migrate/apply (official action)                ->  production (on merge)
                              CE:    gen_migration.sh · apply_migrations_atlas  ->  drift-probe (daily monitor)
                                     deploy_db.sh (CE entrypoint)                   recovery-<run_id> (pre-deploy PITR fork)
```

## How to read this README / how to use this repo

Start here. Each row says what you want to do and where to look.

| You want to... | Do this | Read this section |
| --- | --- | --- |
| Make a schema change (tables, columns, indexes, enums) | Edit `db/schema/schema.sql`, run `./scripts/gen_migration.sh`, commit both, open a PR | [Developer loop](#developer-loop) |
| Make a code-object change (function, procedure, view, trigger) | Edit the file under `db/objects/<layer>/`, push, open a PR | [Developer loop](#developer-loop) |
| Delete an object or change a function signature/return type | Append a JSON line to `db/objects/retirements.jsonl` in the same PR | [Retirements: drops and signature changes](#retirements-drops-and-signature-changes) |
| Understand what CI blocks and why | See the gates table | [What CI fails on (exactly)](#what-ci-fails-on-exactly) |
| Understand how the pipeline behaves end to end | Follow one commit through the three stages | [Architecture](#architecture) |
| Check whether something you need ships here | Look for it in the "not in this repo" table before writing it | [What is NOT in this repo](#what-is-not-in-this-repo) |
| Understand what Atlas Pro would replace | Compare the two columns | [CE vs Pro: what is closed here, what remains](#ce-vs-pro-what-is-closed-here-what-remains) |
| Wire the repo into a fresh workspace/project | Secrets table + setup steps | [Setup](#setup-once), [GitHub secrets](#github-secrets-settings---secrets-and-variables---actions) |
| Investigate a `schema-drift` issue | Run the probe manually against any branch | [Drift monitor](#drift-monitor-scheduled) |

The full design rationale lives outside this repo: the CI/CD plan document
(`Lakebase-CICD-Plan.md`: design decisions, bundle rules, backlog) and the
CE-vs-Pro deck (`atlas-ce-vs-pro-deck-v4.html`: ownership split, cost,
decision gates). This README is the repo's as-built truth.

## Architecture

Three stages. Git is the only source of truth; the deployment engine
provisions resources from it; Lakebase hosts the ephemeral rehearsal
branches and the production branch.

```
┌────────────────────────────────────────────┐
│ 1. SOURCE CODE (Git)                       │
│ schema.sql, migrations, objects, tests,    │
│ databricks.yml, workflows                  │
└─────────────────────┬──────────────────────┘
                      ▼
┌────────────────────────────────────────────┐
│ 2. DEPLOYMENT ENGINE (DAB CLI + Atlas CE)  │
│ databricks.yml: production branch/endpoint │
│ deploy_db.sh: sandbox branches + SQL       │
│ gen_migration.sh: plan · apply: the ledger │
└─────────────────────┬──────────────────────┘
                      ▼
┌────────────────────────────────────────────┐
│ 3. DATABASE RUNTIME (Lakebase DB)          │
│ Copy-on-write Postgres branches:           │
│ pr-<n> rehearsal (24h TTL, fresh fork),    │
│ dev sandboxes (7d TTL), production         │
│ (no expiry), drift-probe (daily,           │
│ self-deleting)                             │
└────────────────────────────────────────────┘
```

Two kinds of branch exist. Git branches carry code release lineage.
Lakebase branches are temporary database state: rehearsal, sandbox, probe,
restore. Never merge a database branch upward; the promotion path is a code
path (PR to `main`, then CD).

## What each file does

| Path | Role |
| --- | --- |
| `db/schema/schema.sql` | Desired state: one declarative SQL file (tables, columns, indexes, FKs, enums). The single source of truth for structural schema. |
| `db/migrations/` | Versioned SQL **generated by Atlas**, never hand-edited. Enforced by the CI immutability gate: a PR may only ADD files here. |
| `db/migrations/atlas.sum` | Atlas integrity file. Rewritten by every generation; Atlas verifies it at apply time, so tampering is always visible. |
| `db/objects/<layer>/` | Code objects (functions, procedures, views, triggers), one file per object, replayed idempotently in layer order `01_types` -> `05_triggers`. The layer numbers are a manual topological sort: CE cannot model objects, so it cannot order them. |
| `db/objects/retirements.jsonl` | DROP manifest applied before each replay, one JSON object per line (`stmt`, `reason`, `requested_in?`). Deleting an object file does NOT drop the object; a function signature/return-type change cannot be replayed by `CREATE OR REPLACE` (it silently creates an overload). Both need a line here. Applied lines are recorded in `infra.retirements_applied` and never re-execute. |
| `db/objects/drift_ignore.jsonl` | Reviewed ignore list for the drift probe's ghost check: one JSON object per line (`object`, `reason`) - names that live on the database but are managed outside `db/objects/`. |
| `db/tests/smoke/` | Read-only smoke tests, safe against production. The default (and CD) suite. |
| `db/tests/integration/` | Data-writing tests, dev/PR branches only (`TEST_SUITE=all`; refused against production). |
| `scripts/gen_migration.sh` | The one command for schema changes: creates a dev branch, builds a throwaway scratch DB from `template0`, runs `atlas migrate diff`, writes the migration. `--check` mode fails when committed migrations do not converge to desired state. |
| `scripts/apply_migrations_atlas.sh` | Applies pending migrations via `atlas migrate apply --tx-mode all`: the entire pending batch is ONE transaction, so a failure halfway through leaves nothing applied. Ledger: `atlas_schema_revisions` (Atlas-managed: exactly-once, per-revision checksums, advisory lock). Baseline adoption is an explicit operator step: `ATLAS_BASELINE=<version>`, never auto-detected. |
| `scripts/apply_objects.py` | Replays `db/objects/` in layer order, and applies `retirements.jsonl` first. The WHOLE run is one transaction: objects applied before a failure roll back with it. |
| `scripts/check_drift.sh` | Drift probe: structural diff (live branch vs `schema.sql`) + object comparison (live branch vs a repo replay on a probe branch). Exits 1 on drift, 2 on probe error. Pro mode (`ATLAS_EDITION=pro`): one object-aware `atlas schema diff` against `schema.sql + db/objects`, no probe branch needed |
| `scripts/rollback_migration.sh` | Pro-only `atlas migrate down` wrapper: reverts the last N migrations with the migrations' pre-revert data checks enforced. Refuses production (restore the recovery branch instead). CE: not available, recovery branch or forward migration |
| `scripts/deploy_db.sh` | Deploy entrypoint: mints a 1-hour OAuth credential, then Atlas validate -> apply -> objects -> tests. Production is reachable only inside GitHub Actions CD. |
| `scripts/new_sandbox.sh` | One-command personal dev branch (7-day TTL). |
| `.github/workflows/pr-validation.yml` | Per-PR checks (see the gates table below). Recreates the `pr-<n>` branch fresh off current production on every run. |
| `.github/workflows/cd-promotion.yml` | On merge to main: DAB deploy + Atlas apply to production, serialized, never cancelled. |
| `.github/workflows/schema-drift-monitor.yml` | Daily scheduled drift probe; on drift it opens/updates a `schema-drift` issue and fails. |
| `.github/workflows/cleanup-orphans.yml` | GC for leftover ephemeral branches. |

## Engine ownership: what Atlas Pro runs, what stays repo code (CE fallback)

The design follows Atlas Pro: wherever the official CLI/actions cover a
concern, the Pro track uses them natively and the bespoke code below is
CE-track-only. "CE track" in the table means the fallback still provides it
when running on the community edition.

| Concern | Pro track | CE track (fallback) |
| --- | --- | --- |
| Plan / generate migration | `ariga/atlas-action/migrate/diff` (official) | `scripts/gen_migration.sh` (template0 scratch in the branch) |
| Safety lint | `migrate/lint` action: native analyzers, PR report | Regex destructive gate + `destructive-approved` label |
| Apply | `migrate/apply` action with a minted 1-hour credential | `scripts/apply_migrations_atlas.sh` (`--tx-mode all`) |
| Cloud versioning | `migrate/push` → [Schema Registry](https://pragmatix.atlasgo.cloud/dirs/4294967296) | Git only (`atlas.sum`) |
| Drift detection | object-aware `atlas schema diff` (one command, no probe branch) | probe-branch replay + definition compare + ghost check |
| Rollback | `atlas migrate down` (`scripts/rollback_migration.sh`, Pro-gated) | recovery branch (pre-deploy PITR fork) or forward migration |
| Objects (functions/views/triggers) | declarative: part of the desired state, planned by Atlas | layered replay + `retirements.jsonl` |
| Managed Schema Monitoring | Atlas Cloud product (connect the prod DB in the portal) | daily probe + `schema-drift` issue |
| RBAC as code | not in either track | not in either track (backlog) |

Deliberately bespoke under BOTH tracks: none for the Pro track's core path.
The only Lakebase-specific glue is credential minting (1-hour OAuth
credential via `generate-database-credential`, below) and the DAB bundle,
that is the platform's own deployment surface, not an Atlas concern.

## Database platform facts (verified live)

- Lakebase Postgres runs **PostgreSQL 17.11** (not 18), so the CI dev-database
  service container and `docker://postgres/17/dev` dev-urls match it.
- Credentials: no static DB URL exists or should. The pattern is the
  documented Lakebase service-principal flow: long-lived SP OAuth secret
  (up to 730 days) → 1-hour workspace token → 1-hour database credential,
  username = SP client id = the SP's Postgres role. See
  [docs/IDENTITIES.md](docs/IDENTITIES.md).

## Developer loop

### Setup (once)

```
git clone https://github.com/Pbash-js/lakebase-cicd-poc-Atlas-enhanced.git
cd lakebase-cicd-poc-Atlas-enhanced
curl -sSf https://atlasgo.sh | sh -s -- --community   # Atlas CE binary
databricks auth login --profile free-edition
```

Day-zero prerequisites (all four are required; a missing one fails mid-deploy):

| Prerequisite | How |
|---|---|
| Python 3.11+ with deps | `python -m pip install -r requirements.txt` (provides psycopg for the object replay) |
| `LAKEBASE_PROJECT` | the Lakebase project id, e.g. `core-app-db` (see databricks.yml targets). `export LAKEBASE_PROJECT=core-app-db` |
| `DATABRICKS_PG_USER` | your Lakebase Postgres role. Find it: `databricks auth describe --profile free-edition` -> the account email (e.g. `you@company.com`) |
| Databricks CLI auth | `databricks auth login --profile free-edition` (above) |

The Lakebase project (`core-app-db`) is created once, out-of-band, and is
never declared in `databricks.yml`: a bundle cannot adopt an existing
project, so the bundle manages branches and endpoints only, referenced by
literal path.

### Day one

```
./scripts/deploy_db.sh    # interactive: creates dev-<you>-<yyyymmdd> off
                          # production (7-day TTL), waits for the endpoint,
                          # applies migrations + objects, runs the tests
```

The result is an isolated, disposable copy of production. Nothing done on
this branch can touch production: the script refuses `TARGET_BRANCH=production`
outside GitHub Actions CD.

Endpoint quota: the account allows a limited number of concurrently active
endpoints. Every PR validation forks a `pr-<n>` branch and CI deploys leave a
`recovery-<run>` branch. If a run fails with "exceeded the limit of concurrently
active endpoints", reclaim capacity by deleting branches whose work is merged:

```
databricks postgres list-branches "projects/$LAKEBASE_PROJECT" -o json
databricks postgres delete-branch "projects/$LAKEBASE_PROJECT/branches/pr-<n>"
```

Never delete `production` or a `recovery-<run>` branch whose CD run has not
finished green.

### The daily loop

Three change shapes, each a PR:

- **Schema change**: edit `db/schema/schema.sql`, run `./scripts/gen_migration.sh`,
  commit BOTH files, push, open a PR. CI verifies the migration matches the
  desired state; on drift it FAILS the check and comments the planned SQL
  (CI never commits).
- **Object change**: edit the object's file under `db/objects/`. It replays
  idempotently on the next deploy to any branch.
- **Both**: one `schema.sql` edit plus object files in the same PR.

Working from a Databricks workspace: add the repo as a Git folder
(workspace -> Add -> Git folder), edit SQL in the workspace editor, commit
and push from the Git folder dialog, then the same PR -> CI -> merge -> CD
flow. The database is never edited directly from the workspace.

### Updating an already-deployed object

Edit its `db/objects/` file; the next deploy replays it. If the object
exists only inside an old applied migration, ship a NEW migration containing
the `CREATE OR REPLACE` AND the matching `db/objects/` file in the same PR.
Never edit an applied migration: that is drift, and the pipeline rejects it.

### Retirements: drops and signature changes

`CREATE OR REPLACE` cannot delete an object or change a function's
signature/return type (it silently creates an overload). Atlas cannot help
here either (verified 2026-10-27 on v1.3.5 Pro: it does not extend a plan to
unchanged dependent objects). In the same PR:
1. Edit the object file (or delete it).
2. Append one JSON line per drop to `db/objects/retirements.jsonl`,
   dependents before dependees (e.g. `DROP VIEW` before the function it
   calls). CASCADE is deliberately not used:

   ```json
   {"stmt": "DROP VIEW IF EXISTS v_order_totals;", "reason": "fn_total_for_customer return type change", "requested_in": "PR#12"}
   ```

3. Replay verifies the result. Each applied statement is recorded in the
   `infra.retirements_applied` table; entries already recorded are skipped,
   so a line never re-executes on later deploys and removing it from the
   file is optional cleanup, not urgency.
4. The drift probe's def comparison keeps the result honest afterwards.

### Rollback

No automated undo. Two forward-moving paths:
- **Forward migration**: a new migration reversing the change (default for schema).
- **Branch fork / PITR**: fork from a past point in time to recover bad data.

## What CI fails on (exactly)

| Gate | Fails when |
| --- | --- |
| Infra-file integrity | PR touches `.github/`, `scripts/` or `databricks.yml` without the `infra-approved` label |
| Migration immutability | PR edits or deletes an existing file in `db/migrations/` (adding new ones is the only allowed change) |
| Destructive change | NEW migration contains `DROP TABLE`, `DROP SCHEMA` or `TRUNCATE` without the `destructive-approved` label. Regex, not parsing: a tripwire for the bot-generated DROP, not a SQL analyzer. Non-concurrent `CREATE INDEX` warns only (it cannot be concurrent under `--tx-mode all`) |
| Atlas plan check | `schema.sql` is not covered by `db/migrations`; the step comments the planned SQL on the PR and fails (CI never commits: run `./scripts/gen_migration.sh` locally) |
| Atlas apply | `atlas.sum` mismatch (tampered history), or a migration fails against the PR branch |
| Tests | pytest fails on the PR branch (`TEST_SUITE=all` there: smoke + integration) |

A label added after a run does not re-fire it. Re-trigger with a fresh
event: an empty commit, or close/reopen the PR.

### Rehearsal branch policy

`pr-<n>` is deleted and re-forked off CURRENT production at the start of
every validation run (copy-on-write, ~2s). A rehearsal therefore always
replays exactly what merging today would do, even after production moved.
Runs for one PR are serialized by the workflow's concurrency group.

## Drift monitor (scheduled)

`.github/workflows/schema-drift-monitor.yml` runs daily. The probe
(`scripts/check_drift.sh`):
1. Structural: `atlas schema diff` of the live branch vs `db/schema/schema.sql`
   (tables, columns, indexes, constraints, enums), excluding tooling schemas.
2. Objects: forks the live branch, replays `db/objects/` on the probe, and
   compares function/view/trigger definitions. Also flags ghost objects
   present on the database but declared nowhere in `db/objects/` (minus the
   reviewed `drift_ignore.jsonl`).
3. On drift: fails, and opens/updates a `schema-drift` GitHub issue with the
   full report. A probe ERROR (auth, connectivity, replay failure) opens a
   distinct issue; it is not drift.

This is detection, not managed monitoring: once a day, no changelog/ERD/
lineage, and the probe costs a short-lived branch per run. The probe source
branch must be TTL-free (a branch with an expiration cannot host the probe
child; production is `no_expiry`). Run it manually against any branch:

```
LAKEBASE_PROJECT=<id> DATABRICKS_PG_USER=<role> \
SOURCE_BRANCH=<branch> PROBE_BRANCH=drift-probe ./scripts/check_drift.sh
```

## Atlas Pro is the deliverable; CE is the fallback

The **Pro track is the target architecture**: the official Atlas actions
own lint, versioning and apply. CE remains the verified fallback that runs
whenever `ATLAS_EDITION=ce`. Live state (2026-10-27): the repo variable is
`pro` on the trial license (expires 2026-11-03); the plan-check step always
plans with the CE diff engine (no cloud dependency) and lint/apply use the
official Pro actions when the edition is pro. After trial expiry the one-line
switch back is `ATLAS_EDITION=ce`. Every CE closure below stays live and
untouched.

| CE gap | Closed in this repo? | How / residual limit |
| --- | --- | --- |
| Half-applied objects | Yes, verified | `apply_objects.py`: one transaction for the whole replay |
| Half-applied migrations | Yes, verified | `atlas migrate apply --tx-mode all`: one transaction for the batch |
| Migrations + objects atomic together | No | Two transactions; each atomic, the pair not (see "not in this repo") |
| Trigger edits skipped | Yes, verified | Trigger files use `DROP TRIGGER IF EXISTS` + `CREATE` |
| Object drops / return-type changes | Yes, verified | `retirements.jsonl` + layered replay; drop order is still manual (Atlas v1.3.5 does not extend plans to unchanged dependents - verified 2026-10-27) |
| Safety lint | Partly | Regex destructive gate + `destructive-approved` label. `atlas.hcl` `skip { drop_table }` also works in CE (verified) but is not enabled: it desyncs `schema.sql` from migrations |
| Drift: tables/indexes/enums | Yes, verified | `atlas schema diff` in the daily probe |
| Drift: functions/views/triggers | Approximated | Probe-branch replay + definition compare + ghost check; name-level, ignore-listed |
| Alerting | Crude | Scheduled workflow + `schema-drift` issue; not managed monitoring |
| Dependency graph, native lint, Schema Monitoring | Not closable in CE | Atlas Pro ($9/dev/mo + $59/project/mo Pipelines + $39/db/mo Monitoring) |

Decision gate: stay on CE while the object count and ordering discipline are
manageable; evaluate Pro when the dependency graph, audit-grade lint or
continuous monitoring become requirements. The deck's concrete trial is a
`numeric(10,2)` -> `numeric(14,4)` widening under a dependent view + function,
run through both paths on a Lakebase branch.

## GitHub configuration (Settings)

Repository variables (Actions -> Variables; SP client IDs, kept for the OIDC switchover):

| Variable | Value |
| --- | --- |
| SP_CI_CLIENT_ID | SP-CI application ID (PR validation + branch GC) |
| SP_CD_CLIENT_ID | SP-CD application ID (CD promotion) |
| SP_MONITOR_CLIENT_ID | SP-MONITOR application ID (drift monitor) |

Repository secrets:

| Secret | Example |
| --- | --- |
| DATABRICKS_HOST | https://dbc-xxxxxxxx.cloud.databricks.com |
| DATABRICKS_TOKEN | PAT or SP token with Lakebase access |
| LAKEBASE_PROJECT | core-app-db |
| DATABRICKS_PG_USER | the Lakebase Postgres role that runs the pipeline |

Auth today is the static `DATABRICKS_TOKEN`. The OIDC switchover (3 SPs,
federation policies, per-workspace subject strings) is fully specced and
stubbed in [docs/IDENTITIES.md](docs/IDENTITIES.md); it is blocked because
federation policies are account-level API, out of Free Edition reach.

## Atlas edition switch (CE <-> Pro)

Atlas is one binary: Pro features unlock with `ATLAS_TOKEN`. The switch is
two repo settings, nothing else changes:

| Setting | `ce` (today) | `pro` |
| --- | --- | --- |
| `ATLAS_EDITION` (Actions variable) | default | lint gate ON, object-aware drift diff ON |
| `ATLAS_TOKEN` (Actions secret) | unused | Atlas Cloud API token |

What Pro adds to the pipeline (all verified live on the trial):

| Feature | Command | Where |
| --- | --- | --- |
| Native lint analyzers | `atlas migrate lint --latest` | `gen_migration.sh --check` rides the plan check on every PR |
| Out-of-band integrity check | `atlas migrate validate` | `apply_migrations_atlas.sh` before every apply (works in CE too) |
| Rollback with pre-revert checks | `atlas migrate down` | `scripts/rollback_migration.sh` (dev branches; production uses the recovery branch) |
| Object-aware drift diff | `atlas schema diff` over `schema.sql + db/objects` | `check_drift.sh` Pro mode: no probe branch, no replay, covers functions/procedures/views/triggers + ghosts |

Note: CI Pro mode needs an Atlas Cloud API token (Settings -> API Tokens at
portal.ariga.io). The CLI login session token is NOT accepted as
`ATLAS_TOKEN` (verified live). Until that token is added, keep
`ATLAS_EDITION=ce`; locally, an `atlas login` session unlocks everything.

### Pro track: official apply + Lakebase credentials

The Pro track uses the official `ariga/atlas-action/migrate/apply@v1`. It
needs a Postgres URL; Lakebase has no static DB URL by design. The
established pattern (Databricks docs: [external apps connect via
API](https://docs.databricks.com/aws/en/oltp/projects/external-apps-manual-api),
[OAuth M2M](https://docs.databricks.com/aws/en/dev-tools/auth/oauth-m2m)):

```
SP OAuth secret (up to 730 days, workspace access on)
  -> M2M client-credentials flow: 1-hour workspace token
  -> generate-database-credential: 1-hour Postgres credential
  -> username = SP client id = that SP's Postgres role (app_pipeline member)
```

The long-lived artifact is the SP secret only; the database password is
self-minted per run. The CD workflow already mints the credential in a
pre-step (`Mint Lakebase database credential`) and hands the URL to the
action. Today the workspace token mints for its own identity; once the SP
OAuth secrets are generated (one console click per SP, steps in
[docs/IDENTITIES.md](docs/IDENTITIES.md)) the same steps run as SP-CI /
SP-CD / SP-MONITOR and no static `DATABRICKS_TOKEN` is used. The OIDC
federation switchover requires account-level API, unavailable on Free
Edition; OAuth M2M secrets work at workspace level on Free Edition, so M2M
is the implemented pattern.

Platform facts (verified live): Lakebase Postgres runs **PostgreSQL 17.11**
(dev containers pinned to `postgres:17` to match). `cd-promotion` accepts a
manual dispatch with a rehearsal-branch target to test the Pro apply path
without production; manual runs are hard-refused when the target is
`production`.

### Alignment with the official Atlas GitHub Actions guide

Source: [atlasgo.io/guides/ci-platforms/github-versioned](https://atlasgo.io/guides/ci-platforms/github-versioned).

| Guide step | This repo | Why |
| --- | --- | --- |
| Bot token as `ATLAS_CLOUD_TOKEN` secret | done (repo secret; token value lives only in the ignored `.env.py`) | official naming kept |
| `ariga/setup-atlas@v0` with `cloud-token` | `pr-validation.yml`, Pro-gated; grant cached for offline access | official install + auth path in CI |
| `ariga/atlas-action/migrate/lint@v1` | `pr-validation.yml`, Pro-gated, `dir-name: lakebase-cicd-poc`, dev-database = postgres:17 service container (matches Lakebase PG 17.11) | native lint report posted on the PR by Atlas Cloud |
| `migrate/push` to the Schema Registry on merge | `cd-promotion.yml`, Pro-gated; registry repo: [pragmatix.atlasgo.cloud/dirs/4294967296](https://pragmatix.atlasgo.cloud/dirs/4294967296) | official step 2 (cloud versioning of the dir) |
| `ariga/atlas-action/migrate/apply@v1` | `cd-promotion.yml`, Pro-gated, against a 1-hour minted Lakebase credential (see "Pro track: official apply" above); CE keeps `apply_migrations_atlas.sh` | Lakebase has no static `DB_URL`: the credential is minted per run by the documented SP OAuth pattern |
| Local `docker://postgres` dev-database | Lakebase template0 scratch DB inside the branch | no Docker dependency; dev DB is the same engine/version as production |

## Sources

- [Atlas Community Edition feature matrix](https://atlasgo.io/community-edition)
- [Atlas versioned migrations (diff, apply, atlas_schema_revisions)](https://atlasgo.io/versioned/migrations)
- [Atlas pricing (Pro seats, Pipelines)](https://atlasgo.io/pricing)
- [Lakebase Cookbook: Branching CI/CD reference](https://lakebase-cookbook.com/docs/examples/branching-cicd/)
- [Databricks Docs: Manage branches (TTL model, 30-day max)](https://docs.databricks.com/aws/en/oltp/projects/manage-branches)
- [Databricks Docs: Typical project setup with Asset Bundles (replace_existing, implicit resources)](https://docs.databricks.com/aws/en/oltp/projects/dabs-typical-project)
- [Databricks Docs: Lakebase authentication (generate-database-credential)](https://docs.databricks.com/aws/en/oltp/projects/authentication)
- [Databricks Blog: Branching databases like code (Glaspoort, per-PR flow)](https://www.databricks.com/blog/branching-databases-code-cicd-pattern-lakebase-production-glaspoort)

## Open items

Closed since this section was written: production test split (smoke vs
integration), CI fail-on-drift (no auto-commit), explicit baseline,
three-dot merge-base diffs, pre-deploy recovery branch in CD, pinned Atlas
version, credential masking, bundle targets for Dev/QA/Stage/Prod
(dev/qa/stage are placeholder stubs until the workspaces exist; prod is
live), SP designations + Lakebase roles + app_pipeline ownership grants
(docs/IDENTITIES.md).
Decisions taken: GC stays weekly-only, dev-branch TTL stays 7 days,
ownership review skipped for the POC.

| # | Change | Open item |
| --- | --- | --- |
| 1 | Ownership | Assign CODEOWNERS to a team instead of individuals; mark the `production` Lakebase branch protected (skipped for this POC by decision) |
| 2 | OIDC credentials | Switch the static `DATABRICKS_TOKEN` to workload federation with the three designated SPs (SP-CI, SP-CD, SP-MONITOR). SPs, Lakebase roles and Postgres grants are DONE (docs/IDENTITIES.md); blocked on federation policies, which need account-level API access beyond Free Edition. The runner error already gave us the exact subject strings |

Carried from v1, still open: RBAC as code, AI-impact review (AI Gateway),
multi-environment promotion with the platform team.
