# Lakebase CI/CD: Architectural Design

Status: implemented. Prose states the design as built; the repo is the source of truth for code.

Atlas Pro track is the deliverable; the Atlas CE track is the fallback. Both run the same repository: the engine is one runtime setting, and a migration applied by either track lands in the same `atlas_schema_revisions` ledger.

---

## 1. System overview

One git repository carries the database schema, the procedural objects, the migration history and the deployment machinery. GitHub Actions runs CI on every pull request and CD on every merge to `main`. Databricks Lakebase Postgres is the database platform, organized as one project with four workspace deployments.

```
SOURCE (Git)                 DEPLOYMENT                              DATABASE (Lakebase)
db/schema/ + db/objects/  -> GitHub Actions + Atlas + DABs      ->  four workspaces
db/migrations/ + atlas.sum   (engine: ATLAS_EDITION = pro | ce)      (one shared project)
```

Design principles:

- **Declarative desired state.** `db/schema/` describes the final state; Atlas ensures the deployed schema matches it (or plans the SQL that makes it so).
- **One-file-per-object.** Functions, procedures, views and triggers each live in their own file, grouped in type folders. This is the production pattern across Atlas, Flyway and Liquibase; the layout survives under both engines.
- **Exactly-once applies.** Every migration is recorded in `atlas_schema_revisions` with checksums; an advisory lock serializes concurrent writers.
- **Forward-only recovery.** SQL undo never runs against production. Production incidents recover from a pre-deploy recovery branch (PITR fork); `atlas migrate down` exists for dev-branch incidents only, Pro-gated.
- **Environments approve, they do not mutate.** The same migration set flows to all four workspaces; environments differ in when they apply it and who approves.

## 2. Deployment topology

Four physically separated Databricks workspaces, one shared Lakebase project (`ams`):

| Workspace | Catalog | Role | Gate |
| --- | --- | --- | --- |
| Dev | `ams_dev` | Rehearsal per PR: migrations, objects, pytest | none |
| QA | `ams_qa` | Functional validation of the same commit | merge to main |
| Stage | `ams_stage` | Production-shaped parity: billing, latency, concurrency, load | named approval |
| Prod | `ams_prod` | Production apply | production environment reviewers |

Isolation properties:

- Each workspace carries its own catalog, identity, secrets and access. Bundle targets change only the workspace host.
- Synced tables and change streams are target-scoped.
- Applications stay in place and connect to Postgres over the network; the database moves through environments, the apps do not.
- Lakebase branches are temporary database state (rehearsal `pr-<n>`, drift probe, recovery). They are never merged upward; git carries release lineage.

## 3. Repository structure

```
db/
├── schema/                  desired state: tables, columns, indexes, constraints, enums
├── objects/
│   ├── 02_functions/  03_procedures/  04_views/  05_triggers/
│   ├── retirements.jsonl    drop manifest (JSONL: stmt/reason/requested_in) (retired objects, signature changes)
│   └── drift_ignore.jsonl   reviewed out-of-band objects (JSONL: object/reason)
├── migrations/              Atlas-generated + atlas.sum (immutable once applied)
└── tests/                   pytest, final stage of every deploy
scripts/
├── gen_migration.sh         plan-check wrapper (lint gate under Pro)
├── apply_migrations_atlas.sh  atlas migrate apply (both editions)
├── apply_objects.py         object replay, one outer transaction
├── check_drift.sh           drift probe (per-edition strategy, section 7)
├── rollback_migration.sh    atlas migrate down wrapper (Pro-gated)
└── branch_test.sh             single entrypoint: migrations -> objects -> tests
.github/workflows/
├── pr-validation.yml        CI: gates + rehearsal on pr-<n>
├── cd-promotion.yml         CD: per-workspace promotion on main
├── schema-drift-monitor.yml scheduled drift probe + issue alerting
databricks.yml               bundle: prod target (dev/qa/stage trimmed until workspaces exist)
docs/IDENTITIES.md           SP identities, subject strings, credential patterns
```

## 4. Engine design: Atlas Pro (deliverable)

Pro is enabled by two GitHub settings: the `ATLAS_EDITION=pro` variable and the `ATLAS_TOKEN` (Atlas Cloud API token) secret. One binary; the token unlocks Pro capabilities.

| Pipeline stage | Implementation |
| --- | --- |
| Lint on PR | official `ariga/atlas-action/migrate/lint` (`pr-validation.yml`): parsed analyzers for destructive, blocking and data-dependent changes; native report posted on the PR |
| Versioning on merge | official `migrate/push` to the Atlas Schema Registry (`cd-promotion.yml`) |
| Apply | official `migrate/apply` action with a minted 1-hour Lakebase credential |
| Drift detection | one object-aware `atlas schema diff` of production against `schema.sql + db/objects`: no probe branch, no replay; covers objects and ghosts |
| Rollback | `scripts/rollback_migration.sh` wrapping `atlas migrate down`: reverse plan plus the migration's pre-revert data checks; refuses production |
| Integrity | `atlas migrate validate` runs before every apply, both editions |
| Monitoring (post-license) | register the production database in Atlas Cloud: continuous drift, changelog, ERD, lineage |

What Pro removes relative to the fallback: the regex destructive gate, the probe-branch drift replay, and manual drop ordering all become product capabilities. The dependency graph (automatic object ordering in place of the numbered-layer convention) is an Atlas Cloud modeling capability and lands with Pipelines, not the CLI alone.

## 5. Engine design: Atlas CE (fallback)

CE runs whenever `ATLAS_EDITION=ce` (the runtime default until the Pro license lands). Every CE gap is closed by repo code, each behavior validated on the live project:

| CE gap | Closure in this repo | Residual limit |
| --- | --- | --- |
| Objects unsupported | `db/objects/` replayed by `apply_objects.py` in layer order, one outer transaction | layer ordering is convention, not a dependency graph |
| Object renames | post-replay ghost check: live-but-undeclared objects fail the deploy; interactive (local TTY) runs can append the retirement lines in one confirmation and re-run; CI/CD hard-fails with the lines |
| Object drops / signature changes | `retirements.jsonl` manifest, dependents before dependees, no CASCADE | manual authorship |
| Trigger edits skipped | `DROP TRIGGER IF EXISTS` + `CREATE TRIGGER` in every trigger file | none |
| No lint | regex destructive gate in `pr-validation.yml`: `DROP TABLE`/`DROP SCHEMA`/`TRUNCATE` fail a PR without the `destructive-approved` label | regex, not parsing |
| Day-zero gap: fresh clone has no migrations and no `.env.local` | `init_project.sh` is the single bootstrap: prompts + `.env.local`, auto-generates the initial baseline when `db/migrations` is empty, then runs the drift probe against production; `gen_migration.sh` / `branch_test.sh` invoke it on first run (skipped in CI, which always sets env vars) | one command to a verified-greenfield repo |
| Migration-directory bloat (100+ files) | `scripts/make_baseline.sh` squashes to one `<ts>_baseline.sql` via Atlas-native `atlas migrate diff baseline` against the full desired state; refuses on drift; existing DBs are stamped with `atlas migrate apply --baseline <v>` (executes nothing) - production BEFORE merging, so CI's `pr-<n>` forks inherit the marking | git history is the archive; recover old migrations with `git revert` |

| No drift detection | `scripts/check_drift.sh`: structural diff + probe-branch replay + definition compare + ghost check | daily schedule, not continuous |
| Half-applied batches | `--tx-mode all` (migrations) and one outer transaction (objects) | migrations and objects remain two transactions |
| Stale rehearsal | `pr-<n>` deleted and re-forked off current production every run | none |

## 6. CI/CD pipeline

**Per PR (pr-validation):**

1. Infra-file integrity gate: PRs touching `.github/`, `scripts/` or `databricks.yml` require the `infra-approved` label.
2. Migration immutability gate: existing files in `db/migrations/` are never edited; new files only (`atlas.sum` exempt, verified at apply time).
3. Destructive-change gate (regex; under Pro the native lint analyzers take over).
4. `pr-<n>` recreated off current production (24h TTL); endpoint readiness (ACTIVE or IDLE; an IDLE endpoint wakes on first connection).
5. Plan check: `atlas migrate diff` against a `template0` scratch DB inside the branch. On drift the bot commits the generated migration and comments the SQL; validation continues in the same run.
6. Rehearsal: migrations, objects, pytest on the PR branch.

**On merge (cd-promotion), serialized per workspace, never cancelled:**

1. Mint a 1-hour database credential (SP OAuth M2M pattern, `docs/IDENTITIES.md`).
2. `databricks bundle deploy` for the target workspace.
3. Recovery branch forked from production before any apply (PITR restore point).
4. Atlas apply (official action under Pro; `apply_migrations_atlas.sh` under CE), then objects, then tests.

**Guards:** `branch_test.sh` refuses production outside GitHub Actions CD. The production branch of the Lakebase project is protected. The `production` GitHub environment carries required reviewers.

## 7. Drift detection

Two strategies behind one interface (`check_drift.sh`):

| | Pro | CE |
| --- | --- | --- |
| Structural | one `atlas schema diff` against `schema.sql + db/objects` | `atlas schema diff` vs `schema.sql` (`--schema public`, tooling schemas excluded) |
| Objects | included in the single diff | probe branch off production (TTL-free source only; TTL branches cannot host children), replay `db/objects`, compare `pg_get_functiondef` / `pg_get_viewdef` / `pg_get_triggerdef` |
| Ghost objects | included | production objects declared nowhere in `db/objects/` or `drift_ignore.jsonl` |

Exit codes: 0 clean, 1 drift, 2 probe error. The scheduled workflow (`schema-drift-monitor.yml`) opens or updates a `schema-drift` issue with the full report; probe errors raise a distinct issue.

## 8. Identity and credentials

- **Human/local:** `databricks auth login` OAuth profile; no tokens in config files.
- **CI/CD:** service principals (SP-CI, SP-CD, SP-MONITOR) authenticating via OAuth M2M client credentials, minting a 1-hour workspace token per run, then a 1-hour Postgres credential from `generate-database-credential`. The Postgres password is never long-lived. Subject strings and the console steps: `docs/IDENTITIES.md`.
- **Why not OIDC federation:** federation policies need account-level API, unavailable on Free Edition; OAuth M2M secrets work at workspace level. M2M is the implemented pattern.
- **Atlas Pro:** `ATLAS_TOKEN` (Atlas Cloud API token from portal.ariga.io) in CI; a local `atlas login` session unlocks everything locally. The CLI session token is not accepted as `ATLAS_TOKEN`.

## 9. Recovery

| Scenario | Mechanism |
| --- | --- |
| Bad deploy on a dev branch | `rollback_migration.sh <n>` (Pro): `atlas migrate down` with pre-revert data checks |
| Bad deploy on production | restore the pre-deploy recovery branch (forked in the CD pre-step); SQL undo never runs in place |
| Point-in-time recovery | Lakebase branch fork / PITR restore, then repoint |
| Tampered history | `atlas.sum` mismatch fails every subsequent Atlas operation; `atlas migrate validate` catches it before apply |
| Out-of-band production change | drift monitor issue; converge by migration, never by adopting the drift |

## 10. Open items

| Item | State | Blocker |
| --- | --- | --- |
| Atlas Cloud bot token | configured; official actions green in CI | closed |
| OIDC identities | SPs, Lakebase roles, Postgres grants done; subject strings in `docs/IDENTITIES.md` | federation policies need account-level API |
| QA/Stage/Dev workspaces | bundle targets defined; project ids are placeholders | workspaces to be provisioned |
| Ownership | CODEOWNERS and protected production branch | skipped for the POC by decision |
| Schema Monitoring | register production in Atlas Cloud after licensing | manual step, post-license |
| Carry-overs | RBAC as code, AI-impact review, multi-environment promotion with the platform team | platform decisions |

## 11. References

- [Atlas Community Edition feature matrix](https://atlasgo.io/community-edition)
- [Atlas CI/CD for versioned migrations](https://atlasgo.io/versioned/setup-cicd)
- [Atlas migration linting](https://atlasgo.io/versioned/lint)
- [Lakebase branching](https://docs.databricks.com/aws/en/oltp/projects/manage-branches)
- [Databricks Asset Bundles](https://docs.databricks.com/aws/en/dev-tools/bundles/index)
- README (operating manual), `docs/IDENTITIES.md` (identities), deck: `X:\Work\V4C\Lakebase\atlas-ce-vs-pro.html`
