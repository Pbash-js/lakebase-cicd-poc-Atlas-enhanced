# Lakebase CI/CD: Architectural Design

Status: implemented. Prose states the design as built; the repo is the source of truth for code.

Atlas Pro carries the pipeline end to end: the declarative desired state and the official GitHub Actions. CI installs the Pro binary via `ariga/setup-atlas@v0`. Every apply lands in the same `atlas_schema_revisions` ledger.

---

## 1. System overview

One git repository carries the database schema, the procedural objects, the migration history and the deployment machinery. GitHub Actions runs CI on every pull request and CD on every push to a baseline branch (`dev`, `qa`, `release/x.y`, `prod`: see the branch model in section 2). Databricks Lakebase Postgres is the database platform: four workspace deployments (dev, qa, stage, prod) over one shared project topology, with ephemeral branches for every other purpose.

```
SOURCE (Git)                 DEPLOYMENT                              DATABASE (Lakebase)
db/schema/ + db/objects/  -> GitHub Actions + Atlas + DABs      ->  dev sandboxes, pr-<n> rehearsal,
db/migrations/ + atlas.sum   (CI/CD: versioned path)               recovery forks, production
```

Design principles:

- **Declarative desired state.** `db/schema/` describes the final state. The local inner loop plans (via Atlas) and applies the diff from it directly; the versioned migrations are frozen artifacts of that same desired state, not a parallel truth.
- **Test first, version last.** The local inner loop (declarative apply to a dev branch) needs no migration. `gen_migration.sh` runs once, when the change is proven, to freeze the artifact the PR rehearses.
- **One-file-per-object.** Functions, procedures, views and triggers each live in their own file, grouped in layer folders (nested folders allowed; the SQL names the schema). Atlas plans objects declaratively from the same files in the local inner loop and the drift check; CI/CD replays them in layer order via `apply_objects.py`.
- **Exactly-once applies.** Every migration is recorded in `atlas_schema_revisions` with checksums; an advisory lock serializes concurrent writers.
- **Single-transaction convergence.** The local declarative apply is one transaction: schema and objects together, all-or-nothing. Every versioned run (PR rehearsal, CD) keeps two transactions (migrations batch, objects replay), each atomic.
- **Forward-only recovery.** SQL undo never runs against production. Production incidents recover from a pre-deploy recovery branch (PITR fork); `atlas migrate down` exists for dev-branch incidents only.
- **CI/CD stay versioned.** The `GITHUB_ACTIONS` gate keeps the declarative apply local-only: the PR rehearsal must exercise the migration artifacts, and production is never converged by a diff.

## 2. Deployment topology

One Lakebase project, branch-based isolation:

| Branch | TTL | Role | Gate |
| --- | --- | --- | --- |
| `production` | none | The database. CD-only target. | production environment reviewers |
| `pr-<n>` | 24h | Rehearsal per PR: migrations, objects, pytest. Deleted and re-forked off current production every run. | CI |
| `dev-<you>-<date>` | 7d | Developer sandbox: declarative apply of the working tree | none |
| `recovery-<run>` | 24h | Pre-deploy PITR restore point, forked by CD before an apply to `production` only (other environments get none) | created by CD |

Lakebase branches are temporary database state. They are never merged upward; git carries release lineage. The promotion path is a code path (PR to the next baseline branch, then CD).

### Git baseline branches

Four baseline branches map 1:1 to the four workspaces; `feat/*`, `hotfix/*` and merge-down branches are short-lived. `main` is retired from the flow: the default branch is `dev`.

| Baseline branch | Workspace | Bundle target | CD trigger | Merge gate |
| --- | --- | --- | --- | --- |
| `dev` | Dev | `dev` | push to `dev` | PR from `feat/*`: 1 review + `validate` check |
| `qa` | QA | `qa` | push to `qa` | PR from `dev`: 1 review + check |
| `release/x.y` | Stage | `stage` | push to `release/x.y` | PR from `qa`: 1 review + CODEOWNERS + check |
| `prod` | Prod | `prod` | push to `prod` | PR from `release/x.y`: 2 reviews + check + `production` environment reviewers |

Rules:

- **Parent is intent.** `feat/*` branches from `dev` (a change that cannot pass QA is not ready to merge). `hotfix/*` branches from `prod`: the parent is always the branch whose state production runs.
- **One live release line.** `release/x.y` is cut from `qa` when a version is ready for Stage parity, promoted to `prod`, and retired when the next line is cut. Baselines never take direct commits; all changes arrive by PR.
- **Hotfix propagation is merge-down.** After the prod fix lands (`hotfix/* -> prod`), merge-down PRs carry it back: `prod -> release/x.y -> qa -> dev`. The exactly-once ledger makes each downward merge apply only what that workspace lacks.
- **Two approval controls.** Branch protection approves the code (per-baseline review counts + required checks); GitHub environments approve the deployment (`stage` and `production` carry required reviewers). A merge never deploys by itself.
- **Environment map is one file.** `config/environments.json` is the single source of truth: git branch -> workspace credentials (by secret name), Lakebase project, database (Lakebase branch) and deploy gate. Every workflow resolves through it; moving an environment to another workspace or database edits that file only (bundle target = the environment key; `databricks.yml` targets are named `dev/qa/stage/prod`). Current topology (Free Edition): one workspace, one project, one long-lived Lakebase branch per environment (`env-dev`, `env-qa`, `env-stage`, `production`). PR rehearsal forks from the base branch's environment database (non-baseline bases fall back to prod).

### Extending to production workspaces

The 4-workspace target (DEV/QA/STAGE/PROD, one Lakebase project and database named `production` per workspace) requires no workflow changes. Steps, in order:

1. In each new workspace: create the Lakebase project, grant the CI/CD service principals the same roles as in the shared workspace (`docs/IDENTITIES.md`).
2. Add one secret pair per workspace (`DATABRICKS_HOST_<ENV>`, `DATABRICKS_TOKEN_<ENV>`) and list both names once in the workflow env blocks (marked in `config/environments.json` header).
3. Edit `config/environments.json`: each row's `host`/`token` point at the new pair, `project` at the new project id, `database` at `production`.
4. Edit `databricks.yml`: each target's branch parent points at the new project.
5. The Free Edition endpoint cap no longer applies at 4 workspaces; until then, keep concurrent active endpoints under ~3 (see operational notes).

Temporary gate relaxation, in force during the single-owner POC (documented decision, audit 2026-10-30): `prod` branch protection requires 2 reviews but `enforce_admins` is false, and the repository admin merges with admin override. Before production cutover (step 1 above), restore the full gate: a second reviewer account, `enforce_admins: true`, and `prevent_self_review` on the `production` and `stage` environments. This relaxation is NOT carried into the 4-workspace topology; the checklist for removing it is part of that cutover.

### Operational notes (Free Edition constraints)

- **Endpoint concurrency cap (~3 active).** Every Lakebase branch endpoint that is ACTIVE counts. Rehearsal fork endpoints stay ACTIVE after their CI run finishes. Before any CD wave, disable endpoints not needed for that wave (`update-endpoint ... spec.disabled {"spec":{"disabled":true}}`); production plus the one target environment is the minimum set. Disabled endpoints wake on first connection.
- **Disabled branches can be reaped.** A branch left disabled may be removed by platform housekeeping; if an environment database goes missing, recreate it off production and let the next CD re-apply pending migrations from the ledger.
- **Capacity errors can surface as plan drift.** The plan check reports a connection-capacity failure as "schema.sql is not covered by db/migrations". Check the log for the endpoint-capacity message before treating a red gate as drift. Classification fix is an open item (section 11).
- **Rerun re-arms gates.** Re-running a CD run that waits on an environment approval re-requests that approval.

## 3. Repository structure

```
db/
├── schema/                  desired state: tables, columns, indexes, constraints, enums,
│                            extensions (00_extensions.sql); CREATE SCHEMA marks a schema managed
├── objects/
│   ├── 01_types/ .. 05_triggers/   code objects, one file each; nested folders allowed
│   ├── retirements.jsonl    drop manifest (JSONL: stmt/reason/requested_in)
│   └── drift_ignore.jsonl   reviewed out-of-band objects (JSONL: object/reason)
├── migrations/              Atlas-generated + atlas.sum (immutable once applied)
└── tests/                   pytest (smoke: prod-safe; integration: PR/dev only)
scripts/
├── lib.sh                   shared Lakebase glue: hosts, tokens, endpoint/branch waits,
│                            schema allowlist (public + declared schemas)
├── init_project.sh          single bootstrap (section 7)
├── branch_test.sh           deploy entrypoint: local declarative | CI/CD migrations->objects
├── build_desired.py         desired-state builder (schema + object layers, recursive)
├── apply_desired.py         declarative apply (plan via schema diff, one tx)
├── gen_migration.sh         freeze a versioned migration from db/schema
├── apply_migrations_atlas.sh  atlas migrate validate + migrate apply --tx-mode all
├── resolve_env.py           git branch -> environment (config/environments.json)
├── apply_objects.py         object replay (CI/CD), one outer transaction
├── check_drift.sh           drift probe (single object-aware diff, section 6)
└── rollback_migration.sh    atlas migrate down wrapper (dev branches)
.github/
└── workflows/               pr-validation, cd-promotion, schema-drift-monitor
docs/
├── DESIGN.md                this file
└── IDENTITIES.md            SP identities, subject strings, credential patterns
```

## 4. Engine: Atlas Pro

Pro unlocks with `ATLAS_TOKEN` (Atlas Cloud API token for the atlas CLI license check). In CI, the binary itself is installed by `ariga/setup-atlas@v0`. Locally, an `atlas login` session unlocks everything.

### 4.1 The exact Atlas commands

Every Atlas invocation in this repo, grouped by the script that wraps it. Atlas does the SQL-level work: diffing, migration generation, `atlas.sum` checksums, the `atlas_schema_revisions` ledger, apply ordering and lint. The scripts supply what Atlas cannot: Lakebase credentials and branch lifecycle, a clean scratch database, code-object handling in the versioned path, safety guards, and the 0/1/2 exit-code contract the workflows branch on.

**Scripts and the Atlas commands they wrap**

| Script | Atlas commands (exact form in this repo) | What Atlas does | What the script adds (non-Atlas) |
| --- | --- | --- | --- |
| `gen_migration.sh` | `atlas migrate diff <name> --dir file://db/migrations --to file://<desired.sql> --dev-url <scratch>`; `atlas migrate hash --dir file://db/migrations`. With `--check` the diff runs into a throwaway copy of the directory, and the plan check also runs `atlas migrate lint --latest 1 --dir file://db/migrations --dev-url <scratch>` | Turns the desired state into exactly one migration; keeps `atlas.sum` authoritative; lint uses parsed analyzers for destructive, blocking and data-dependent changes | Dev branch (1d TTL) and `template0` scratch database, created and dropped per run; desired state from `build_desired.py --schema-only`; hard-fails if the plan contains code-object DDL; CRLF to LF before hashing; auto-stages the file; exit contract 0 clean / 1 drift / 2 infra |
| `apply_migrations_atlas.sh` | `atlas migrate validate --dir file://db/migrations`; `atlas migrate apply --url <db> --dir file://db/migrations --lock-timeout 60s --tx-mode all`; operator-only `... --baseline <version>` | Integrity gate, then exactly-once apply against the ledger; the whole pending batch is one transaction; advisory lock serializes writers | URL encoding of the role; repo-relative directory (a Windows `file://X:/` path silently resolves empty and turns apply into a no-op); empty-directory guard. Used by the PR rehearsal and local versioned deploys; CD uses the official `migrate/apply` action instead (second table) |
| `apply_desired.py` | `atlas schema diff --from <target-url> --to file://<desired.sql> --dev-url <scratch> --schema <allowlist> --exclude <globs> --format '{{ sql . "  " }}'` | Plans the FULL desired state (tables and code objects) against the live database, object-aware, with correct ordering, as pure SQL; the schema allowlist (`public` + every `CREATE SCHEMA` in `db/schema`) keeps `__db_system` and the ledger schema out of the plan | Strips the platform-owned `DROP EVENT TRIGGER on_create_*/on_drop_*` statements, then executes the rest in ONE transaction (`lock_timeout 5s`). This replaces the rejected `atlas schema apply` (second table). Exit 0 applied/clean, 1 apply failed, 2 Atlas/infra error. Reached only from the local path of `branch_test.sh` |
| `check_drift.sh` | One `atlas schema diff --from <prod-url> --to file://<.tmp_pro/desired.sql> --dev-url <scratch> --schema <allowlist> --exclude public.schema_migrations --exclude "public.grant_*"` | A single diff covers structural drift, object drift and ghosts (live objects missing from the desired state appear as DROPs) | `template0` scratch database; filters platform noise (`on_create_*`, `DROP EVENT TRIGGER`); maps every outcome to exit 0 clean / 1 drift / 2 probe error |
| `rollback_migration.sh` | `atlas migrate down --dir file://db/migrations --url <db> --dev-url <scratch> <n>` | Reverse plan plus pre-revert data checks | Refuses `production` (branch restore, never in-place SQL undo); `template0` scratch database |
| `branch_test.sh` | None directly; calls the scripts above | n/a | Deploy entrypoint. Refuses environment databases outside GitHub Actions; creates or reuses the dev branch (7d TTL); mints the 1-hour credential; picks the path (below); runs pytest (`TEST_SUITE=all` refused on production) |
| `apply_objects.py` | None | n/a (locally, Atlas plans objects declaratively instead) | Replays `db/objects` in layer order in one outer transaction (a savepoint per file); `retirements.jsonl` drops with a strict whitelist and no CASCADE; post-replay ghost check. The CI/CD object path (see the path table below) |
| `build_desired.py` | None; builds the file Atlas reads as `--to` | n/a | Concatenates `db/schema/*.sql` (+ `db/objects` layers unless `--schema-only`) in a deterministic order; the single builder for `branch_test.sh`, `check_drift.sh` and `gen_migration.sh` |
| `lib.sh`, `init_project.sh`, `resolve_env.py` | None | n/a | `lib.sh`: Lakebase CLI glue (host, 1-hour token, endpoint and branch waits, schema allowlist). `init_project.sh`: bootstrap (section 7). `resolve_env.py`: git branch to workspace secret names, project and database via `config/environments.json` |

Which path `branch_test.sh` takes:

| Context | Path |
| --- | --- |
| Local | `build_desired.py` then `apply_desired.py`: schema and objects converge declaratively in one transaction, no migration |
| PR rehearsal (`GITHUB_ACTIONS=true`) | `apply_migrations_atlas.sh` then `apply_objects.py` (the declarative path is gated off) |
| CD | Official `migrate/apply` action for migrations, then `branch_test.sh` with `SKIP_MIGRATIONS=1`: `apply_objects.py` and smoke tests. Objects are replayed, not Atlas-planned |

**Atlas invoked outside the scripts (workflows and the Atlas platform)**

| Atlas capability | Where | Role |
| --- | --- | --- |
| `ariga/setup-atlas@v0` | `pr-validation.yml`, `cd-promotion.yml`, `schema-drift-monitor.yml` | Installs the Pro binary; the scripts use it as `ATLAS_BIN=atlas` |
| `ariga/atlas-action/migrate/apply` (`tx-mode: all`) | `cd-promotion.yml` | Official versioned apply against the minted credential: Atlas, not our wrapper, owns the deployment |
| `atlas schema apply --auto-approve` | Rejected, never used | Would be the one-step declarative apply; unusable on Lakebase (platform constraint below). `apply_desired.py` replaces it: Atlas plans and orders, our executor filters platform statements and runs the rest in one transaction |

**Where the boundaries sit**

| Layer | Owns |
| --- | --- |
| Workflow YAML | When things run; secrets and environment approval gates; the official Atlas actions; the lint gate; the production recovery fork |
| Shell scripts | Sequencing; branch and scratch-database lifecycle; Atlas invocation; the 0/1/2 exit-code contract |
| Python | Anything needing a transaction or a catalog query: executing the plan, object replay, ghost check, definition compare, desired-state build |
| Atlas | Diffing, migration generation, `atlas.sum`, the revisions ledger, apply ordering, lint, down |

The rule of thumb: Atlas operates on a database URL and a migrations directory. Obtaining that URL for an ephemeral Lakebase branch, making a clean scratch database for it, and everything after it (objects, tests, safety rules) is the scripts' job.

Platform constraint (live-tested on Atlas v1.3.5-2a6a8a7-canary, 2026-11-02, disposable Lakebase branch; report in the repo test log): under a **database-scope URL**, Atlas plans `DROP EVENT TRIGGER` for the three platform-owned `on_create_schema`/`on_create_table_or_view`/`on_create_sequence` event triggers and `DROP SCHEMA __db_system` — no tested `--exclude` form matches event triggers (`[type=...]` selectors either no-op or over-match and empty the plan) — and the apply fails with `must be owner` (42501; the objects are owned by `cloud_admin`). No `on_drop_*` event trigger exists on Lakebase. Under a **`search_path=public` URL (schema scope, both sides, `schema { src }` in atlas.hcl)** these objects are never inspected and `schema apply` executes, failing only on ordinary dependency ordering unless the three `grant_*` functions are excluded with an unqualified pattern (`exclude = ["grant_*"]`; a schema-qualified pattern silently does not apply in schema scope). This repo still routes every declarative apply through `apply_desired.py` — Atlas plans, the executor disposes — because it needs one transaction over the full database scope with platform statements filtered; the filter matches only `on_create_*` event triggers. Two further live facts: `schema apply --dry-run` hangs (use `--auto-approve` only against disposable targets), and Lakebase's `TEMPLATE template0` is not pristine (a scratch inherits every user schema plus the platform objects), so a clean database for `schema apply`'s dev check does not exist without manual cleanup.

## 5. Versioned path (all of CI/CD)

The migration pipeline is the audit spine and runs on every PR and deploy:

1. `gen_migration.sh`: dev branch + `template0` scratch, `atlas migrate diff` over `db/schema/*.sql` only (a plan containing object DDL hard-fails: objects ride the replay, never migrations).
2. CI rehearses on a fresh `pr-<n>` fork: lint, immutability gate, plan check (migrations must converge to desired state), apply, objects, `TEST_SUITE=all`.
3. CD: credential mint, recovery fork (production target only), official apply, objects (`apply_objects.py`), smoke tests, to the target workspace baseline.

## 6. Drift detection

One strategy behind one interface (`check_drift.sh`): a single object-aware `atlas schema diff` against the full desired state (all declared schemas) covers structural drift, object drift and ghost objects (live objects declared nowhere in `db/objects/` or `drift_ignore.jsonl`; extension-owned objects, `deptype='e'`, never count).

Exit codes: 0 clean, 1 drift, 2 probe error. The scheduled workflow (`schema-drift-monitor.yml`) opens or updates a `schema-drift` issue with the full report; probe errors raise a distinct issue.

## 7. Day zero

`init_project.sh` is designed so a fresh clone reaches a verified-clean state without drift hoops:

1. Prompts project id + Postgres role; CLI auth check.
2. Project missing: offers creation (`create-project`, waits for DONE, waits for the production endpoint). Greenfield works end to end.
3. Writes `.env.local`: `LAKEBASE_PROJECT`, `DATABRICKS_PG_USER`.
4. Empty `db/migrations`: generates the initial baseline and stops with next steps (production is empty by definition; the baseline ships via PR -> CD).
5. Otherwise probes the **committed baseline**: the probe runs inside a clean `git archive HEAD` export, never the working tree. Uncommitted WIP cannot block setup; it is reported as a count and converges on a dev branch via `branch_test.sh`. Drift means the committed repo and production disagree.

## 8. Identity and credentials

- **Human/local:** `databricks auth login` OAuth profile; no tokens in config files.
- **CI/CD:** service principals (SP-CI, SP-CD, SP-MONITOR) authenticating via OAuth M2M client credentials, minting a 1-hour workspace token per run, then a 1-hour Postgres credential from `generate-database-credential`. The Postgres password is never long-lived. Subject strings and the console steps: `docs/IDENTITIES.md`.
- **Why not OIDC federation:** federation policies need account-level API, unavailable on Free Edition; OAuth M2M secrets work at workspace level. M2M is the implemented pattern.
- **Atlas Pro:** CI uses one secret: `ATLAS_TOKEN` (for the atlas CLI license check), minted at portal.ariga.io; the binary is installed by `ariga/setup-atlas@v0`. A local `atlas login` session unlocks everything locally. The CLI session token is not accepted as `ATLAS_TOKEN`.

## 9. Recovery

| Scenario | Mechanism |
| --- | --- |
| Bad deploy on a dev branch | `rollback_migration.sh <n>`: `atlas migrate down` with pre-revert data checks |
| Bad deploy on production | restore the pre-deploy recovery branch (forked in the CD pre-step for production targets); SQL undo never runs in place |
| Bad deploy on dev / qa / stage | no recovery branch is forked; re-fork the environment database off production and let CD re-apply from the ledger, or ship a forward migration |
| Point-in-time recovery | Lakebase branch fork / PITR restore, then repoint |
| Tampered history | `atlas.sum` mismatch fails every subsequent Atlas operation; `atlas migrate validate` catches it before apply |
| Out-of-band production change | drift monitor issue; converge by migration, never by adopting the drift |

## 10. Open items

| Item | State | Blocker |
| --- | --- | --- |
| OIDC identities | SPs, Lakebase roles, Postgres grants done; subject strings in `docs/IDENTITIES.md` | federation policies need account-level API |
| Ownership | branch protection live on all four baselines; CODEOWNERS in place | closed for the POC (single owner) |
| Multi-environment promotion | proven through dev -> qa -> stage (section 2) | closed for the POC; prod promotion pending real workspaces |
| Endpoint hygiene automation | manual disable/enable per CD wave (operational notes, section 2) | small GC workflow to disable spent `pr-<n>` endpoints |
| Capacity-error classification | endpoint-capacity failures surface as plan-drift in the plan check | classify as infra error (exit 2 semantics) with a retry hint |
| Carry-overs | RBAC as code, AI-impact review | platform decisions |

## 11. References

- [Atlas versioned migrations](https://atlasgo.io/versioned/migrations)
- [Atlas CI/CD for versioned migrations](https://atlasgo.io/versioned/setup-cicd)
- [Atlas migration linting](https://atlasgo.io/versioned/lint)
- [Databricks Docs: Manage branches](https://docs.databricks.com/aws/en/oltp/projects/manage-branches)
- [Databricks Docs: Lakebase authentication](https://docs.databricks.com/aws/en/oltp/projects/authentication)
- [Databricks Asset Bundles](https://docs.databricks.com/aws/en/dev-tools/bundles/index)
- README (operating manual), `docs/IDENTITIES.md` (identities)
