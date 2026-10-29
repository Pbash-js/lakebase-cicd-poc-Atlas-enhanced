# Lakebase CI/CD: Architectural Design

Status: implemented. Prose states the design as built; the repo is the source of truth for code.

Atlas Pro is the deliverable: the declarative desired state, the official GitHub Actions and the Schema Registry carry the pipeline. Atlas CE is a documented fallback with known limitations (section 6). Both run the same repository: the engine is one runtime setting, and a migration applied by either lands in the same `atlas_schema_revisions` ledger.

---

## 1. System overview

One git repository carries the database schema, the procedural objects, the migration history and the deployment machinery. GitHub Actions runs CI on every pull request and CD on every merge to `main`. Databricks Lakebase Postgres is the database platform: one project (`core-app-db`), one production branch, and ephemeral branches for every other purpose.

```
SOURCE (Git)                 DEPLOYMENT                              DATABASE (Lakebase)
db/schema/ + db/objects/  -> GitHub Actions + Atlas + DABs      ->  dev sandboxes, pr-<n> rehearsal,
db/migrations/ + atlas.sum   (engine: ATLAS_EDITION = pro | ce)      recovery forks, production
```

Design principles:

- **Declarative desired state.** `db/schema/` describes the final state. Pro plans and applies the diff from it directly; the versioned migrations are frozen artifacts of that same desired state, not a parallel truth.
- **Test first, version last.** The local inner loop (Pro declarative apply to a dev branch) needs no migration. `gen_migration.sh` runs once, when the change is proven, to freeze the artifact the PR rehearses.
- **One-file-per-object.** Functions, procedures, views and triggers each live in their own file, grouped in layer folders (nested folders allowed; the SQL names the schema). Under Pro, Atlas plans objects declaratively from the same files; under CE they replay in layer order.
- **Exactly-once applies.** Every migration is recorded in `atlas_schema_revisions` with checksums; an advisory lock serializes concurrent writers.
- **Single-transaction convergence.** The Pro declarative apply is one transaction: schema and objects together, all-or-nothing. CE keeps two transactions (migrations batch, objects replay), each atomic.
- **Forward-only recovery.** SQL undo never runs against production. Production incidents recover from a pre-deploy recovery branch (PITR fork); `atlas migrate down` exists for dev-branch incidents only.
- **CI/CD stay versioned.** The `GITHUB_ACTIONS` gate keeps the declarative apply local-only: the PR rehearsal must exercise the migration artifacts, and production is never converged by a diff.

## 2. Deployment topology

One Lakebase project, branch-based isolation:

| Branch | TTL | Role | Gate |
| --- | --- | --- | --- |
| `production` | none | The database. CD-only target. | production environment reviewers |
| `pr-<n>` | 24h | Rehearsal per PR: migrations, objects, pytest. Deleted and re-forked off current production every run. | CI |
| `dev-<you>-<date>` | 7d | Developer sandbox: Pro declarative apply of the working tree | none |
| `recovery-<run>` | 7d | Pre-deploy PITR restore point, forked by CD before any apply | created by CD |
| drift-probe | self-deleting | Object-replay comparison (CE drift mode) | scheduled monitor |

Lakebase branches are temporary database state. They are never merged upward; git carries release lineage. The promotion path is a code path (PR to `main`, then CD).

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
├── init_project.sh          single bootstrap (section 8)
├── branch_test.sh           deploy entrypoint: Pro declarative | CE migrations->objects
├── build_desired.py         desired-state builder (schema + object layers, recursive)
├── apply_desired.py         Pro declarative apply (plan via schema diff, one tx)
├── gen_migration.sh         freeze a versioned migration from db/schema
├── apply_migrations_atlas.sh  atlas migrate apply --tx-mode all
├── apply_objects.py         CE object replay, one outer transaction
├── check_drift.sh           drift probe (per-edition strategy, section 7)
└── rollback_migration.sh    atlas migrate down wrapper (Pro, dev branches)
.github/
├── workflows/               pr-validation, cd-promotion, schema-drift-monitor
└── actions/setup-atlas/     composite: pinned Atlas install for CI
docs/
├── DESIGN.md                this file
└── IDENTITIES.md            SP identities, subject strings, credential patterns
```

## 4. Engine: Atlas Pro (deliverable)

Pro unlocks with `ATLAS_TOKEN` (Atlas Cloud API token) and `ATLAS_EDITION=pro`. Locally, `init_project.sh` writes `ATLAS_EDITION=pro` into `.env.local`, so the declarative inner loop is the developer default; in CI the repo variable decides and `ce` is the default when unset.

| Pipeline stage | Implementation |
| --- | --- |
| Local inner loop | `branch_test.sh`: one declarative apply of the FULL desired state (`build_desired.py` -> `apply_desired.py`), schema + objects, one transaction, no migration needed |
| Declarative apply | `atlas schema diff` (pure-SQL format) plans; `apply_desired.py` executes verbatim minus Lakebase platform-owned statements, in one transaction with a 5s lock timeout |
| Lint on PR | official `ariga/atlas-action/migrate/lint` (`pr-validation.yml`): parsed analyzers for destructive, blocking and data-dependent changes; native report on the PR |
| Versioning on merge | official `migrate/push` to the Atlas Schema Registry (`cd-promotion.yml`) |
| Apply to production | official `migrate/apply` action with a minted 1-hour Lakebase credential |
| Drift detection | one object-aware `atlas schema diff` of the target against the full desired state: no probe branch, no replay; covers objects and ghosts |
| Rollback | `rollback_migration.sh` wrapping `atlas migrate down`: reverse plan plus pre-revert data checks; refuses production |
| Integrity | `atlas migrate validate` runs before every apply, both editions |
| Monitoring (post-license) | register the production database in Atlas Cloud: continuous drift, changelog, ERD, lineage |

Platform constraint (verified on v1.3.5): `atlas schema apply --auto-approve` is unusable on Lakebase. Atlas plans `DROP EVENT TRIGGER` for the platform-owned `on_create_*`/`on_drop_*` triggers; they are not excludable (`--exclude` does not match them; `atlas.hcl` `skip` blocks are lint-analyzer only) and the DROP fails with "must be owner". `apply_desired.py` is the consequence: Atlas still owns planning and ordering; the executor filters the platform statements and runs the rest as one transaction. A schema allowlist (`public` + every `CREATE SCHEMA` in `db/schema`) keeps `__db_system` and the Atlas ledger schema out of every plan.

## 5. Versioned path (both editions, and all of CI/CD)

The migration pipeline is the audit spine and runs everywhere regardless of edition:

1. `gen_migration.sh`: dev branch + `template0` scratch, `atlas migrate diff` over `db/schema/*.sql` only (a plan containing object DDL hard-fails: objects ride the replay, never migrations).
2. CI rehearses on a fresh `pr-<n>` fork: lint (Pro) or regex destructive gate (CE), immutability gate, plan check (migrations must converge to desired state), apply, objects, `TEST_SUITE=all`.
3. CD: credential mint, recovery fork, official apply (Pro) or `apply_migrations_atlas.sh --tx-mode all` (CE), objects, smoke tests, to production.

## 6. Engine: Atlas CE (fallback)

CE runs whenever `ATLAS_EDITION=ce`. It is a serviceable fallback, not an equal. The repo closes what repo code can close; the rest are hard limitations:

| CE gap | Closure in this repo | Hard limitation |
| --- | --- | --- |
| Objects unsupported | `db/objects/` replayed by `apply_objects.py` in layer order, one outer transaction | layer ordering is convention, not a dependency graph |
| Object renames/drops | post-replay ghost check + `retirements.jsonl` (interactive one-shot cleanup locally; hard fail in CI/CD) | manual authorship, drop order manual |
| Trigger edits skipped | `DROP TRIGGER IF EXISTS` + `CREATE TRIGGER` in every trigger file | none |
| No lint | regex destructive gate + `destructive-approved` label | regex, not parsing |
| No object-aware drift | probe-branch replay + definition compare + ghost check | name-level approximation, daily |
| No rollback | recovery branch or forward migration | none |
| Half-applied batches | `--tx-mode all` (migrations), one outer transaction (objects) | migrations and objects remain two transactions: a schema+object PR can apply schema and fail objects |
| No schema convergence without a migration | `gen_migration.sh` | the test-first loop collapses to version-first: every schema experiment needs a migration before `branch_test` |
| No cloud versioning/monitoring | Git + scheduled probe | Git is the only history; detection is once daily |

Day-zero and bloat closures (kept from earlier iterations): `init_project.sh` is the single bootstrap (section 8); the migration directory stays clean by generation, not by squashing (no `make_baseline.sh`; git history is the archive).

## 7. Drift detection

Two strategies behind one interface (`check_drift.sh`):

| | Pro | CE |
| --- | --- | --- |
| Structural | one `atlas schema diff` against the full desired state (all declared schemas) | `atlas schema diff` vs `db/schema` (allowlist, tooling schemas excluded) |
| Objects | included in the single diff | probe branch off production (TTL-free source only), replay `db/objects`, compare `pg_get_functiondef` / `pg_get_viewdef` / `pg_get_triggerdef` |
| Ghost objects | included | production objects declared nowhere in `db/objects/` or `drift_ignore.jsonl`; extension-owned objects (`deptype='e'`) never count |

Exit codes: 0 clean, 1 drift, 2 probe error. The scheduled workflow (`schema-drift-monitor.yml`) opens or updates a `schema-drift` issue with the full report; probe errors raise a distinct issue. Pro's Schema Monitoring product is the upgrade path after licensing.

## 8. Day zero

`init_project.sh` is designed so a fresh clone reaches a verified-clean state without drift hoops:

1. Prompts project id + Postgres role; CLI auth check.
2. Project missing: offers creation (`create-project`, waits for DONE, waits for the production endpoint). Greenfield works end to end.
3. Writes `.env.local`: `LAKEBASE_PROJECT`, `DATABRICKS_PG_USER`, `ATLAS_EDITION=pro`.
4. Empty `db/migrations`: generates the initial baseline and stops with next steps (production is empty by definition; the baseline ships via PR -> CD).
5. Otherwise probes the **committed baseline**: the probe runs inside a clean `git archive HEAD` export, never the working tree. Uncommitted WIP cannot block setup; it is reported as a count and converges on a dev branch via `branch_test.sh`. Drift means the committed repo and production disagree.

## 9. Identity and credentials

- **Human/local:** `databricks auth login` OAuth profile; no tokens in config files.
- **CI/CD:** service principals (SP-CI, SP-CD, SP-MONITOR) authenticating via OAuth M2M client credentials, minting a 1-hour workspace token per run, then a 1-hour Postgres credential from `generate-database-credential`. The Postgres password is never long-lived. Subject strings and the console steps: `docs/IDENTITIES.md`.
- **Why not OIDC federation:** federation policies need account-level API, unavailable on Free Edition; OAuth M2M secrets work at workspace level. M2M is the implemented pattern.
- **Atlas Pro:** `ATLAS_TOKEN` (Atlas Cloud API token from portal.ariga.io) in CI; a local `atlas login` session unlocks everything locally. The CLI session token is not accepted as `ATLAS_TOKEN`.

## 10. Recovery

| Scenario | Mechanism |
| --- | --- |
| Bad deploy on a dev branch | `rollback_migration.sh <n>` (Pro): `atlas migrate down` with pre-revert data checks |
| Bad deploy on production | restore the pre-deploy recovery branch (forked in the CD pre-step); SQL undo never runs in place |
| Point-in-time recovery | Lakebase branch fork / PITR restore, then repoint |
| Tampered history | `atlas.sum` mismatch fails every subsequent Atlas operation; `atlas migrate validate` catches it before apply |
| Out-of-band production change | drift monitor issue; converge by migration, never by adopting the drift |

## 11. Open items

| Item | State | Blocker |
| --- | --- | --- |
| Atlas Cloud bot token | configured; official actions green in CI | closed |
| OIDC identities | SPs, Lakebase roles, Postgres grants done; subject strings in `docs/IDENTITIES.md` | federation policies need account-level API |
| Ownership | CODEOWNERS and protected production branch | skipped for the POC by decision |
| Schema Monitoring | register production in Atlas Cloud after licensing | manual step, post-license |
| Carry-overs | RBAC as code, AI-impact review, multi-environment promotion | platform decisions |

## 12. References

- [Atlas versioned migrations](https://atlasgo.io/versioned/migrations)
- [Atlas CI/CD for versioned migrations](https://atlasgo.io/versioned/setup-cicd)
- [Atlas migration linting](https://atlasgo.io/versioned/lint)
- [Databricks Docs: Manage branches](https://docs.databricks.com/aws/en/oltp/projects/manage-branches)
- [Databricks Docs: Lakebase authentication](https://docs.databricks.com/aws/en/oltp/projects/authentication)
- [Databricks Asset Bundles](https://docs.databricks.com/aws/en/dev-tools/bundles/index)
- README (operating manual), `docs/IDENTITIES.md` (identities)
