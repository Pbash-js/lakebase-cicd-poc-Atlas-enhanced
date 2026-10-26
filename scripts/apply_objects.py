"""Apply stateless code objects idempotently, in layer order.
01_types -> 02_functions -> 03_procedures -> 04_views -> 05_triggers.
Every file must be safe to replay (CREATE OR REPLACE / DROP+CREATE).

The WHOLE run is one transaction: objects applied before a failure are
rolled back with it (no half-applied object set).

Retirements (drops): db/objects/retirements.txt lists DROP statements,
one per line, executed before the replay in the order written. Use it
to retire deleted objects (removing an object file does NOT drop it)
and to drop functions whose signature/return type changed (CREATE OR
REPLACE cannot change a signature; it silently creates an overload).
Drop dependents before dependees, e.g. DROP VIEW before the function
it calls. CASCADE is deliberately not used.
"""
import argparse, sys
from pathlib import Path

import psycopg

LAYER_ORDER = ["01_types", "02_functions", "03_procedures", "04_views", "05_triggers"]
RETIREMENTS = "retirements.txt"


def load_retirements(root: Path):
    """One SQL statement per line; blank lines and -- comments ignored."""
    f = root / RETIREMENTS
    if not f.is_file():
        return []
    stmts = []
    for raw in f.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("--"):
            continue
        stmts.append(line.rstrip(";"))
    return stmts


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", required=True)
    ap.add_argument("--port", default="5432")
    ap.add_argument("--dbname", default="databricks_postgres")
    ap.add_argument("--user", required=True)
    ap.add_argument("--password", required=True)
    ap.add_argument("--sslmode", default="require")
    ap.add_argument("--objects-root", default="db/objects")
    args = ap.parse_args()

    root = Path(args.objects_root)
    files = []
    for layer in LAYER_ORDER:
        d = root / layer
        if d.is_dir():
            files += sorted(d.glob("*.sql"))

    retirements = load_retirements(root)

    try:
        with psycopg.connect(
            host=args.host, port=args.port, dbname=args.dbname,
            user=args.user, password=args.password, sslmode=args.sslmode,
        ) as conn, conn.transaction():
            if retirements:
                print(f"  retirements ({len(retirements)} statement(s)):")
                for stmt in retirements:
                    head = stmt if len(stmt) <= 60 else stmt[:57] + "..."
                    conn.execute(stmt)
                    print(f"    {head:<58} RETIRED")
            for path in files:
                sql = path.read_text(encoding="utf-8")
                label = str(path.relative_to(root))
                try:
                    # savepoint inside the outer transaction: a failing file
                    # marks itself; the outer block rolls everything back
                    with conn.transaction():
                        conn.execute(sql)
                    print(f"  {label:<50} APPLIED (idempotent replay)")
                except Exception as e:
                    print(f"  {label}: FAILED - {e}", file=sys.stderr)
                    raise
    except Exception as e:
        msg = str(e).strip()
        print(f"  object run aborted, transaction rolled back: {msg}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
