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

def test_function_and_view():
    with _conn() as c:
        row = c.execute("SELECT order_count, total_cents FROM v_order_totals ORDER BY customer_id LIMIT 1").fetchone()
        assert row[0] >= 1 and row[1] > 0

def test_seed_present():
    with _conn() as c:
        assert c.execute("SELECT count(*) FROM orders").fetchone()[0] >= 3


def test_shipments_trigger_and_proc():
    # exercises migration 004 + sp_register_shipment + trg_shipments_audit
    with _conn() as c:
        order_id = c.execute("SELECT order_id FROM orders ORDER BY order_id LIMIT 1").fetchone()[0]
        c.execute("CALL sp_register_shipment(%s, %s)", (order_id, "dhl"))
        row = c.execute("SELECT status, carrier FROM shipments WHERE order_id = %s", (order_id,)).fetchone()
        assert row is not None and row[0] == "in-transit" and row[1] == "dhl"
        st = c.execute("SELECT status FROM orders WHERE order_id = %s", (order_id,)).fetchone()[0]
        assert st == "shipped"
