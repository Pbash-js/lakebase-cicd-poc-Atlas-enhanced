"""Data-writing integration tests: DEV/PR branches only. Never run against
production (cd-promotion runs the smoke suite only; deploy_db.sh defaults to
smoke unless TEST_SUITE=all)."""
import os, psycopg

def _conn():
    return psycopg.connect(
        host=os.environ["PGHOST"], port=os.environ.get("PGPORT", "5432"),
        dbname=os.environ.get("PGDATABASE", "databricks_postgres"),
        user=os.environ["PGUSER"], password=os.environ["PGPASSWORD"],
        sslmode="require")

def test_shipments_trigger_and_proc():
    # exercises migration 004 + sp_register_shipment + trg_shipments_audit
    with _conn() as c:
        order_id = c.execute("SELECT order_id FROM orders ORDER BY order_id LIMIT 1").fetchone()[0]
        c.execute("CALL sp_register_shipment(%s, %s)", (order_id, "dhl"))
        row = c.execute("SELECT status, carrier FROM shipments WHERE order_id = %s", (order_id,)).fetchone()
        assert row is not None and row[0] == "in-transit" and row[1] == "dhl"
        st = c.execute("SELECT status FROM orders WHERE order_id = %s", (order_id,)).fetchone()[0]
        assert st == "shipped"
