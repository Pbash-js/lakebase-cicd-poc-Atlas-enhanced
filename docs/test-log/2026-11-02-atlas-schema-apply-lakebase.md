# Lakebase / Atlas `schema apply` trigger-drop conjecture — LIVE TEST REPORT

**Atlas:** v1.3.5-2a6a8a7-canary (Pro build) · **Tested:** 2026-11-02, isolated disposable Lakebase branch `conjecture-check` (project `core-app-db`, forked from production, deleted after the test) · **All commands run from a scratch directory outside the CI/CD POC repo.**

## Catalog ground truth (verified via SQL on the sandbox)

- Event triggers: exactly **3**, all `ddl_command_end`, all owner `cloud_admin`:
  `on_create_schema`, `on_create_table_or_view`, `on_create_sequence`.
- **No `on_drop_*` event trigger exists.** Any spec text mentioning `on_drop_*` is wrong.
- `public` carries 3 platform functions owned by `cloud_admin`:
  `grant_all_on_new_sequences`, `grant_select_on_new_objects`, `grant_usage_on_new_schema`.
- **`CREATE DATABASE ... TEMPLATE template0` is NOT pristine on Lakebase**: the scratch inherited
  every user schema (`infra`, `test_ce`, `test_pro`, `new_shared_schema`) plus the platform objects.
  A "clean" database does not exist without manual cleanup (user-owned schemas are droppable;
  `__db_system` on real databases is not user-droppable).

## Results

| # | Configuration | Command | Result |
|---|---|---|---|
| A | bare URL (no `search_path`), `atlas schema diff` | plan | **plans 3× `DROP EVENT TRIGGER "on_create_*"`** + 3× `DROP FUNCTION grant_*` + all user objects |
| B2 | `search_path=public` on BOTH `--from` and `--to` | `atlas schema diff` | **zero `DROP EVENT TRIGGER` in the plan** (scope-mismatch error if only one side is scoped: "cannot diff a database connection with a schema public") — but `DROP FUNCTION grant_*` is still planned |
| C | bare URL + `--exclude "function.public.grant_*" --exclude "event_trigger.*"` | `atlas schema diff` | both excludes **silently ignored**: 3 event-trigger drops + 3 grant drops remain |
| C2 | `--exclude "public.grant_*"` | `atlas schema diff` | grant drops removed; **event-trigger drops remain (3)** |
| C3 | `--exclude "[type=event_trigger]"` | `atlas schema diff` | **no match**: event-trigger drops remain |
| C4 | `--exclude "[type=function, name=public.grant_*]"` | `atlas schema diff` | selector **over-matches: entire plan emptied** (not a usable exclusion) |
| D | bare URL, `atlas schema apply --auto-approve` (live execution) | apply | **fails 42501 `pq: must be owner of schema __db_system`**; the executed plan contains the 3 `DROP EVENT TRIGGER` statements (would fail identically — owner `cloud_admin`) |
| F | `schema {}`-scoped src + `search_path=public` URLs, `exclude=["public.grant_*"]` | `atlas schema apply --auto-approve` | executes; **no event-trigger statements at all**; fails 2BP01 on `grant_all_on_new_sequences` (the schema-qualified exclude pattern did not apply in schema scope) |
| G | same, `exclude=["grant_*"]` (unqualified) | `atlas schema apply --auto-approve` | grant drops gone; next failure is ordinary drop-ordering (`DROP TABLE orders` blocked by dependent views, 2BP01) — **no ownership errors, no event-trigger statements** |

`atlas schema apply --dry-run` **hangs** on this setup (both configs); all apply evidence above is from real `--auto-approve` executions on the disposable sandbox.

## Verdict per claim

1. **"schema apply plans DROP EVENT TRIGGER for on_create_*"** — CONFIRMED, but **scope-dependent**: true for database-scope URLs, never for `search_path=public`-scoped URLs (B2, F, G).
2. **"--exclude can't match them"** — CONFIRMED for every syntax tried (C, C2, C3, C4). In database scope, event-trigger drops could not be excluded by any pattern; in schema scope they are simply never inspected.
3. **"DROP fails with must be owner"** — CONFIRMED live (42501 on `__db_system`; the `on_create_*` drops follow and are equally owned by `cloud_admin`).
4. **"`skip` blocks are lint-analyzer only"** — NOT TESTED here.
5. **"edition-independent"** — NOT TESTED (Pro binary only).
6. **"`schema apply` unusable on Lakebase"** — REFUTED as an absolute: with `schema { src }` + `search_path=public` + `exclude=["grant_*"]`, apply executes against the platform and fails only on ordinary dependency ordering. Database-scope apply is the unusable configuration.
7. **Script gap (grant functions)** — CONFIRMED: with scoped URLs the grant functions are still planned for drop and hit 2BP01 unless excluded. Our `strip_noise` filter alone is insufficient in a scoped world; `--exclude` must carry them.

## Reproducer commands (exact)

```bash
# ground truth
psql "$URL" -c "SELECT evtname, pg_get_userbyid(evtowner) FROM pg_event_trigger;"

# A: bare URL plans event-trigger drops
atlas schema diff --from "postgres://...databricks_postgres?sslmode=require" \
  --to "file://empty" --dev-url "$SCRATCH" --format '{{ sql . "  " }}'
#   -> 3x DROP EVENT TRIGGER "on_create_*";

# B2: scoped URLs never plan them (requires BOTH sides scoped)
atlas schema diff --from "$URL&search_path=public" --to "file://empty?search_path=public" \
  --dev-url "$SCRATCH&search_path=public" --format '{{ sql . "  " }}'

# D: live ownership failure (database scope)
atlas schema apply --env lakebase-bare --var pg_url="$URL" --var dev_url="$SCRATCH" --auto-approve
#   -> Error: executing statement "DROP SCHEMA \"__db_system\" CASCADE;":
#      pq: must be owner of schema __db_system (42501)
#   (plan contains 3x DROP EVENT TRIGGER)

# G: usable configuration (schema scope + unqualified exclude)
# atlas.hcl: env with schema { src = "file://empty" }, url/dev with search_path=public,
#            exclude = ["grant_*"]
atlas schema apply --env lakebase-scoped3 --var pg_url="$URL" --var dev_url="$SCRATCH" --auto-approve
#   -> no event-trigger statements, no ownership errors; next failure is ordinary
#      view-dependency drop ordering (2BP01), unrelated to the platform
```

## Recommended spec wording (replaces the current DESIGN.md 4.1 platform constraint)

> Lakebase creates `__db_system`, three `grant_*` functions in `public`, and event triggers
> `on_create_schema`, `on_create_table_or_view`, `on_create_sequence`, all owned by `cloud_admin`.
> Under a database-scope URL, Atlas (Pro, v1.3.5-2a6a8a7-canary, 2026-11-02, live repro) plans
> `DROP EVENT TRIGGER` for all three and `DROP SCHEMA __db_system`, which fail with `must be owner`
> (42501); none of the tested `--exclude` forms match event triggers. Under a `search_path=public`
> URL (schema scope, both sides) these objects are never inspected and `schema apply` executes,
> failing only on ordinary dependency ordering unless the grant functions are excluded with an
> unqualified pattern (`exclude = ["grant_*"]` in the schema-scoped env). This repo still routes
> every declarative apply through `apply_desired.py` (Atlas plans, our executor disposes) because
> it needs one transaction over the full database scope with platform statements filtered; the
> filter matches only `on_create_*` event triggers — no `on_drop_*` event trigger exists on
> Lakebase.
