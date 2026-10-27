"""Read-only smoke tests: safe against production. CD runs this suite only."""
import os, psycopg

def _conn():
    return psycopg.connect(
        host=os.environ["PGHOST"], port=os.environ.get("PGPORT", "5432"),
        dbname=os.environ.get("PGDATABASE", "databricks_postgres"),
        user=os.environ["PGUSER"], password=os.environ["PGPASSWORD"],
        sslmode="require")

def test_migrations_exactly_once():
    with _conn() as c:
        n = c.execute("SELECT count(*) FROM atlas_schema_revisions.atlas_schema_revisions").fetchone()[0]
        assert n >= 2
        # the ledger must be at the newest migration file, not merely non-empty:
        # a partially applied deploy must fail the smoke suite.
        from pathlib import Path
        versions = sorted(p.name.split("_")[0] for p in Path("db/migrations").glob("*.sql"))
        newest = versions[-1]
        top = c.execute("SELECT max(version) FROM atlas_schema_revisions.atlas_schema_revisions").fetchone()[0]
        assert str(top) == newest, f"ledger at {top}, newest migration is {newest}"

def test_function_and_view():
    with _conn() as c:
        row = c.execute("SELECT order_count, total_cents FROM v_order_totals ORDER BY customer_id LIMIT 1").fetchone()
        assert row[0] >= 1 and row[1] > 0

def test_seed_present():
    with _conn() as c:
        assert c.execute("SELECT count(*) FROM orders").fetchone()[0] >= 3

def test_triggers_present():
    with _conn() as c:
        names = {r[0] for r in c.execute(
            "SELECT tgname FROM pg_trigger WHERE NOT tgisinternal").fetchall()}
        assert {"trg_orders_audit", "trg_shipments_audit"} <= names
