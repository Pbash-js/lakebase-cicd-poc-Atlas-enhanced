"""Pro declarative apply: plan with `atlas schema diff`, execute in one tx.

Why not `atlas schema apply --auto-approve`? Atlas insists on dropping the
Lakebase platform-owned event triggers (on_create_*/on_drop_*): they are
DB-level resources that --exclude cannot filter (verified 2026-10-28,
atlas.hcl `skip` blocks don't apply to diff/apply), and the DROP fails with
"must be owner" on Lakebase, aborting the whole apply. So Atlas still owns
the PLANNING (native diff, correct ordering, lint); this script executes the
plan verbatim minus the platform-owned statements, in one transaction.

Usage: python scripts/apply_desired.py --url <db> --desired <file> \
         --dev-url <scratch> --atlas-bin atlas [--exclude g1,g2]
Exit: 0 applied/clean, 1 drift-plan failed to apply, 2 atlas/infra error.
"""
import argparse, re, subprocess, sys

import psycopg

# Statements Atlas plans for Lakebase platform resources; not ours to police
# (same filter as check_drift.sh Pro mode).
NOISE = re.compile(r"(?im)^.*DROP EVENT TRIGGER .*(on_create|on_drop).*$\n?")
# Atlas prefixes each statement with a `-- <verb> ...` comment line; strip the
# comment line directly above a dropped statement too.
COMMENT = re.compile(r"(?im)^-- .*$\n?")


def plan(atlas, url, desired, dev_url, schemas, excludes) -> str:
    cmd = [atlas, "schema", "diff",
           "--from", url,
           "--to", f"file://{desired}",
           "--dev-url", dev_url,
           "--format", '{{ sql . "  " }}']
    for s in schemas:
        cmd += ["--schema", s]
    for g in excludes:
        cmd += ["--exclude", g]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(r.stdout + r.stderr)
        sys.exit(2)
    return r.stdout


def strip_noise(sql: str) -> str:
    # remove `DROP EVENT TRIGGER` statements AND their preceding -- comment
    lines = sql.splitlines(keepends=True)
    out, i = [], 0
    while i < len(lines):
        if re.match(r"(?i)DROP EVENT TRIGGER .*(on_create|on_drop)", lines[i]):
            i += 1
            continue
        if (i + 1 < len(lines)
                and lines[i].lstrip().startswith("--")
                and re.match(r"(?i)DROP EVENT TRIGGER .*(on_create|on_drop)", lines[i + 1])):
            i += 2
            continue
        out.append(lines[i])
        i += 1
    return "".join(out)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--desired", required=True)
    ap.add_argument("--dev-url", required=True)
    ap.add_argument("--atlas-bin", default="atlas")
    ap.add_argument("--schemas", default="public", help="comma-separated schema allowlist")
    ap.add_argument("--exclude", default="", help="comma-separated --exclude globs")
    a = ap.parse_args()

    sql = strip_noise(plan(a.atlas_bin, a.url, a.desired, a.dev_url,
                           [s for s in a.schemas.split(",") if s],
                           [g for g in a.exclude.split(",") if g]))
    if not sql.strip():
        print("  ✓ branch already matches desired state")
        return 0

    print(f"  plan: {len([l for l in sql.splitlines() if l.strip() and not l.strip().startswith('--')])} statement(s)")
    try:
        with psycopg.connect(a.url, autocommit=True) as conn:
            with conn.transaction():
                conn.execute("SET LOCAL lock_timeout = '5s'")
                conn.execute(sql)
    except Exception as e:
        print(f"  ✗ declarative apply failed, transaction rolled back: {e}", file=sys.stderr)
        return 1
    for l in sql.splitlines():
        if l.strip() and not l.strip().startswith("--"):
            print(f"    {l.strip()[:100]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
