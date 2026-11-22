# Target environment setup checklist

Standing this pipeline up on the planned environment, starting from this
repo. Work top to bottom; each phase gates the next. Terse tables; every
item is either a command or a console step.

## 0. Fresh repo from this one (the clone-and-repoint pattern)

Do NOT fork: GitHub cannot fork a repo within one account, and a fork
shares the upstream's PR/CI surface. Create a fresh repo instead:

```
gh repo create <new-owner>/<new-repo> --private
git clone --no-local https://github.com/Pbash-js/lakebase-cicd-poc-Atlas-enhanced.git
cd lakebase-cicd-poc-Atlas-enhanced
git remote rename origin upstream
git remote add origin https://github.com/<new-owner>/<new-repo>.git
git push -u origin --all && git push origin --tags
```

Source repo secrets are unreadable by design: every secret in Phase A is
set fresh on the new origin.

## 1. GitHub repository (Settings)

| Item | Value | Notes |
| --- | --- | --- |
| Default branch | `dev` | merge chain: dev -> qa -> release/** -> prod |
| Environments | `dev`, `qa`, `stage`, `production` | all four must exist; an empty `deploy_env` starves CD of its token |
| Environment reviewers | none on dev/qa; required reviewers on stage + production | per-environment choice |
| Environment secret | `DATABRICKS_TOKEN_CD` on each of the four | deploy-capable token; only the CD promote job reads it |
| Repo secrets | `DATABRICKS_HOST`, `DATABRICKS_TOKEN_CI`, `LAKEBASE_PROJECT`, `DATABRICKS_PG_USER`, `ATLAS_TOKEN` | `ATLAS_TOKEN` only after Phase 5 |
| Repo variables | `SP_CI_CLIENT_ID`, `SP_CD_CLIENT_ID` | client ids are not credentials |
| Branch protection | `dev`: PR + required `validate` check | stage/production gates are the environment reviewers |
| Label | `infra-approved` | PRs touching `.github/`, `config/`, `scripts/`, `databricks.yml` need it after review (infra-integrity gate) |
| Docs-only PRs | run no checks; merge with `--admin` | pr-validation paths filter |

Token mint (interim owner PAT, until the SPs exist on the target):

```
databricks auth login --profile <target>
databricks tokens create --json '{"lifetime_seconds": 2592000, "comment": "ci interim owner PAT (until SPs)"}' --output json
printf '%s' "$PAT" | gh secret set DATABRICKS_TOKEN_CI
for e in dev qa stage production; do printf '%s' "$PAT" | gh secret set DATABRICKS_TOKEN_CD --env "$e"; done
```

Never paste a token through chat or a tool transcript. At the SP
switchover the values change, not the workflow references
(`docs/IDENTITIES.md`).

## 2. Databricks identities (target workspace)

| Item | How |
| --- | --- |
| SP-CI, SP-CD | create two service principals; enable Workspace access |
| OAuth secrets | per SP: Secrets tab, 730-day lifetime, scopes `sql` (+`all-apis` if the mint API needs it); store as the values for `DATABRICKS_TOKEN_CI` (SP-CI) and `DATABRICKS_TOKEN_CD` (SP-CD) |
| Lakebase OAuth roles | `databricks postgres create-role ... --json '{"spec":{"identity_type":"SERVICE_PRINCIPAL","postgres_role":"<client-id>"}}'` on `production` |
| `app_pipeline` group | run the ownership block ONCE on the target's `production` branch before the first SP-driven deploy (`docs/IDENTITIES.md`); skip `cloud_admin`-owned objects |
| Interim fallback | no SPs available? owner PAT from Phase 1 works unchanged; same Postgres role path |

## 3. Lakebase project + branches

| Item | How |
| --- | --- |
| Project | `databricks postgres create-project <project-id>` (or adopt existing; DABs cannot adopt an existing project, so branches/endpoints only in the bundle) |
| Branches | one long-lived branch per environment: `env-dev`, `env-qa`, `env-stage`, `production` (names must match `config/environments.json` `database` values) |
| Compute | Free Edition suspends endpoints after 1 idle day: re-enable with `databricks postgres update-endpoint <branch>/endpoints/primary "spec.disabled" --json '{"spec":{"disabled":false}}'` |
| Endpoint cap | ~3 ACTIVE endpoints max. Before a CD wave, disable endpoints not in the wave; disabled endpoints wake on first connection |

## 4. Pipeline config

| Item | How |
| --- | --- |
| `config/environments.json` | edit `git_branch` patterns, `project`, `database`, `deploy_env` per target; `host`/`token` stay secret NAMES. One workspace: all rows share `DATABRICKS_HOST` |
| `databricks.yml` | targets are named dev/qa/stage/prod, matching the environment keys; no change unless targets are renamed |
| Trigger paths | `pr-validation.yml` and `cd-promotion.yml` must include `db/schema/**` in `paths`; script-only commits never fire CD |

## 5. Atlas Pro (only remaining external dependency)

| Item | How |
| --- | --- |
| Plan | active subscription at pragmatix.atlasgo.cloud/purchase |
| `ATLAS_TOKEN` | Atlas Cloud API token from portal.ariga.io (a CLI `atlas login` session token is rejected; verified live) |
| Binary | `ariga/setup-atlas@v0` installs it in CI; pin by versioned asset URL locally |

## 6. Validation sequence (in order)

| # | Test | Green means |
| --- | --- | --- |
| 1 | docs-only PR to `dev`, admin merge | branch protection + merge path work |
| 2 | code PR to `dev`: `validate` green | rehearsal fork, plan check, apply, objects, smoke on the target |
| 3 | merge to `dev`: CD Promotion green | DAB deploy + credential mint + Atlas apply on `env-dev` |
| 4 | merge dev -> qa -> release/** -> prod | full chain; stage/prod stop on required reviewers |
| 5 | daily drift monitor green next morning | production vs Git probe |

Known-good reference: the 2026-11-22 dev dry run on this workspace passed
resolve, credential selection, DAB deploy and Lakebase credential mint;
the only failure was the expired Atlas Pro plan (Phase 5).
