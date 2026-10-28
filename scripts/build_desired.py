"""Build the full Pro desired state: db/schema/*.sql + db/objects in layer order.

One file, one consumer contract (stdout path printed last if --print).
Used by branch_test.sh (Pro declarative apply) and check_drift.sh (Pro drift
diff) so the desired state is built exactly once, one source of truth.

Usage: python scripts/build_desired.py --out <path>
"""
import argparse, glob, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from apply_objects import LAYER_ORDER


def build(repo: Path) -> str:
    parts = []
    schema_files = sorted(repo.glob("db/schema/*.sql"), key=lambda f: f.name != "schema.sql")
    if not schema_files:
        sys.exit("✗ db/schema is empty")
    parts += [f.read_text(encoding="utf-8") for f in schema_files]
    for layer in LAYER_ORDER:
        for f in sorted((repo / "db/objects" / layer).rglob("*.sql")):
            parts.append(Path(f).read_text(encoding="utf-8"))
    return "\n\n".join(parts)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True, help="path to write desired.sql to")
    a = ap.parse_args()
    out = Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(build(Path(__file__).resolve().parent.parent), encoding="utf-8")
    print(out)
