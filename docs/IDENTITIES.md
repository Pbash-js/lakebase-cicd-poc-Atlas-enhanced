# Deploy identities: service principals, credentials, federation (setup + usage)

STATUS: SP setup complete (principals, Lakebase roles, Postgres grants via
the `app_pipeline` group). Credential switchover is ONE console step away:
generate an OAuth secret per SP (below). Workflows run on the static
workspace PAT today, split by scope: `DATABRICKS_TOKEN_CI` (repository
secret) for PR and monitor jobs, `DATABRICKS_TOKEN` (an environment secret
on every CD environment) for the CD deploy job only. A PR run can no longer
read the deploy-capable token; the SP switchover replaces the values, not
the workflow references.

## The credential pattern (documented, established)

Source: Databricks docs.
[external apps connect via API](https://docs.databricks.com/aws/en/oltp/projects/external-apps-manual-api)
and
[OAuth M2M](https://docs.databricks.com/aws/en/dev-tools/auth/oauth-m2m).

```
SP OAuth secret (long-lived, up to 730 days, Workspace access enabled)
  -> client-credentials M2M flow -> 1-hour workspace token
  -> generate-database-credential -> 1-hour Postgres credential
  -> connect as username = SP client id (the SP's Postgres role)
```

The Postgres password is NEVER long-lived: the SP self-mints a fresh
credential per run. This is the pattern the CD workflow implements
("Mint Lakebase database credential" step). The OIDC federation switchover
requires account-level API (unavailable on Free Edition); OAuth M2M secrets
work at workspace level on Free Edition, so M2M is the implemented pattern.

### The one-time console step (per SP, needs admin UI)

1. Workspace → Settings → Identity and access → Service principals → open
   the SP (client ids below) → **Secrets** tab → **Generate secret**.
2. Lifetime: 730 days. Scopes: `sql` (and `all-apis` if the mint API needs
   the wider scope).
3. Confirm "Workspace access" is enabled on the SP's Configurations tab.
4. Store as GitHub secrets:
   - `DATABRICKS_CLIENT_ID` = the SP's application (client) id
   - `DATABRICKS_CLIENT_SECRET` = the generated secret
5. The Databricks CLI then self-authenticates via
   `DATABRICKS_AUTH_TYPE=client-credentials` (or the SDK equivalent) and the
   minted database credential belongs to that SP's Postgres role.

### Secret scoping (implemented; the SP pass replaces the values)

The GitHub-side scoping is DONE (audit fix, 2026-10-30). When the SP secrets
are generated, only the values change:

1. `DATABRICKS_TOKEN` is an ENVIRONMENT secret on every CD environment
   (`dev`, `qa`, `stage`, `production`); the CD job resolves it because it
   declares `environment: <deploy_env>`. stage/production additionally carry
   required reviewers.
2. `DATABRICKS_TOKEN_CI` is a repository secret for PR/monitor jobs (today:
   the same PAT value; after the switchover: SP-CI / SP-MONITOR tokens).
3. The workflow references already point the right way: pr-validation.yml and
   schema-drift-monitor.yml read `secrets.DATABRICKS_TOKEN_CI`; the CD
   promote job reads `secrets.DATABRICKS_TOKEN` (environment-scoped).

Residual until the Lakebase project roles are split: all pipeline identities
are members of `app_pipeline` (which owns the schema), so a leaked CI or
monitor credential could still write to production. The real control is
Lakebase project RBAC per identity, which needs the SP secrets first.

Identity map (client id → role):

## The three identities

| SP | Application (client) ID | Runs in | Purpose |
| --- | --- | --- | --- |
| SP-CI | `eacad5b0-694c-4cf8-b56f-63ec17b92f95` | `pr-validation.yml` | Per-PR rehearsal on `pr-<n>` branches |
| SP-CD | `fc3eb1ed-dbfc-4785-b712-c030294f153f` | `cd-promotion.yml` (environment `production`) | Deploys to production: DAB + migrations + objects + smoke tests |
| SP-MONITOR | `53648115-4f50-40f3-8372-4e11002cc180` | `schema-drift-monitor.yml` | Daily drift probe: read production, replay objects on a probe branch |

The client IDs are stored as GitHub Actions REPOSITORY VARIABLES (not
secrets, they are not credentials): `SP_CI_CLIENT_ID`, `SP_CD_CLIENT_ID`,
`SP_MONITOR_CLIENT_ID`.

## Federation policies (GitHub OIDC): THE BLOCKED STEP

Each SP needs a service-principal federation policy (account-level, created
once by an account admin). This requires account-level API access, which
the Free Edition workspace token does not have. The exact subjects are
known from a live runner attempt (the Databricks error echoes the token's
`sub` verbatim): on this GitHub account the `sub` carries enterprise
decorations (login@org-id, repo@repo-id).

| SP | Subject |
| --- | --- |
| SP-CI | `repo:Pbash-js@78909321/lakebase-cicd-poc-Atlas-enhanced@1407457562:pull_request` (PR runs) AND `repo:Pbash-js@78909321/lakebase-cicd-poc-Atlas-enhanced@1407457562:ref:refs/heads/main` (scheduled GC runs) |
| SP-CD | `repo:Pbash-js@78909321/lakebase-cicd-poc-Atlas-enhanced@1407457562:environment:production` |
| SP-MONITOR | `repo:Pbash-js@78909321/lakebase-cicd-poc-Atlas-enhanced@1407457562:ref:refs/heads/main` (scheduled runs run on main) |

Issuer for all: `https://token.actions.githubusercontent.com`.

If a workflow fails with `github-oidc auth: ... TOKEN_INVALID (Ensure a
valid federation policy has been configured)`, the error echoes the exact
`subject:` the token carried: set the policy subject to that string.

Create/update with:
```
databricks account service-principal-federation-policy create <SP-account-id> --json '{
  "oidc_policy": {
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:Pbash-js@78909321/lakebase-cicd-poc-Atlas-enhanced@1407457562:environment:production"
  }
}'
```

Workflow side (the OIDC option, NOT currently wired): `permissions: id-token: write` plus
`DATABRICKS_AUTH_TYPE: github-oidc` and `DATABRICKS_CLIENT_ID: <sp-uuid>`
in every job env.

## Postgres roles (Lakebase)

Each SP has a Lakebase OAuth role on the project's branches (created via
`databricks postgres create-role ... --json '{"spec":{"identity_type":"SERVICE_PRINCIPAL","postgres_role":"<client-id>"}}'`):

| Role on `production` | Postgres role name | SP |
| --- | --- | --- |
| `rol-fbc7-1vaatlr84s` | `fc3eb1ed-dbfc-4785-b712-c030294f153f` | SP-CD |
| `rol-o5yt-xnl97kra8k` | `eacad5b0-694c-4cf8-b56f-63ec17b92f95` | SP-CI |
| `rol-44hi-tngy944byc` | `53648115-4f50-40f3-8372-4e11002cc180` | SP-MONITOR |

New branches fork production and inherit these roles copy-on-write, so one
setup per project covers every future `pr-*`, sandbox and probe branch.

### Ownership model: the `app_pipeline` group

Lakebase does not allow granting the human owner's OAuth role to anyone
(no ADMIN option), so privileges are delegated through a Postgres GROUP
role. Created once per project (on `production`):

```sql
CREATE ROLE app_pipeline NOLOGIN;
GRANT app_pipeline TO "<sp-cd-client-id>", "<sp-ci-client-id>", "<sp-monitor-client-id>";
ALTER SCHEMA public OWNER TO app_pipeline;
-- all app objects: tables, sequences, views, functions, procedures, enum types
-- (pg loop: ALTER ... OWNER TO app_pipeline; skip cloud_admin-owned objects)
ALTER SCHEMA atlas_schema_revisions OWNER TO app_pipeline;  -- the ledger
GRANT USAGE, CREATE ON SCHEMA public TO app_pipeline;
GRANT ALL ON ALL TABLES IN SCHEMA public TO app_pipeline;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO app_pipeline;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA public TO app_pipeline;
```

Why: `atlas migrate apply` and `apply_objects.py` must ALTER and CREATE
objects, and PostgreSQL requires ownership for ALTER. With `app_pipeline`
as owner and all three SPs as members (INHERIT default), every pipeline
identity has exactly the DDL rights it needs, and the human owner
(the project owner's identity) is also a member for administration.

Note for fresh workspaces: run the ownership block ONCE on that workspace's
production branch (as the creating user) BEFORE the first SP-driven deploy.
`ALTER ... OWNER` statements that hit platform-owned objects
(`cloud_admin`: e.g. the `grant_*` event-trigger functions) are skipped;
they are not app objects.

## Local development

No SP involvement: `databricks auth login`, then `./scripts/branch_test.sh`.
The scripts mint a 1-hour database credential for the CALLER's identity, so
local runs use your own role; CI runs use the SP's role.

## What would break if an SP disappears

| If revoked | Failure mode |
| --- | --- |
| SP-CI | PR validation and branch GC fail at the first `databricks` CLI call |
| SP-CD | cd-promotion fails before touching production (fail-closed) |
| SP-MONITOR | The daily drift probe errors and opens the `schema-drift` "probe error" issue |
