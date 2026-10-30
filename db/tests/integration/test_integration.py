"""Data-writing integration tests: DEV/PR branches only. Never run against
production (cd-promotion runs the smoke suite only; deploy_db.sh defaults to
smoke unless TEST_SUITE=all)."""
import os, psycopg, pytest

def _conn():
    return psycopg.connect(
        host=os.environ["PGHOST"], port=os.environ.get("PGPORT", "5432"),
        dbname=os.environ.get("PGDATABASE", "databricks_postgres"),
        user=os.environ["PGUSER"], password=os.environ["PGPASSWORD"],
        sslmode="require")

def _new_order(c, status="new"):
    """Create a self-contained customer+order so tests never depend on the
    environment database's leftover data state."""
    cust = c.execute(
        "INSERT INTO customers (name) VALUES (%s) RETURNING customer_id",
        (f"it-cust-{os.urandom(4).hex()}",)).fetchone()[0]
    return c.execute(
        "INSERT INTO orders (customer_id, status) VALUES (%s, %s) RETURNING order_id",
        (cust, status)).fetchone()[0]

def test_shipments_trigger_and_proc():
    # exercises migration 004 + sp_register_shipment + trg_shipments_audit
    with _conn() as c:
        order_id = _new_order(c)
        c.execute("CALL sp_register_shipment(%s, %s)", (order_id, "dhl"))
        row = c.execute("SELECT status, carrier FROM shipments_original WHERE order_id = %s", (order_id,)).fetchone()
        assert row is not None and row[0] == "in-transit" and row[1] == "dhl"
        st = c.execute("SELECT status FROM orders WHERE order_id = %s", (order_id,)).fetchone()[0]
        assert st == "shipped"

def test_register_shipment_rejects_cancelled_and_double():
    # audit finding 10: a cancelled order must not ship; a second call must
    # not create a duplicate shipment. Each guarded CALL runs in a SAVEPOINT:
    # the RAISE aborts the transaction, ROLLBACK TO discards only the aborted
    # statement so the following asserts see real state.
    with _conn() as c:
        cancelled = _new_order(c, status="cancelled")
        c.execute("SAVEPOINT s1")
        with pytest.raises(psycopg.errors.RaiseException):
            c.execute("CALL sp_register_shipment(%s, %s)", (cancelled, "dhl"))
        c.execute("ROLLBACK TO SAVEPOINT s1")
        assert c.execute("SELECT COUNT(*) FROM shipments_original WHERE order_id = %s", (cancelled,)).fetchone()[0] == 0
        shipped = _new_order(c)
        c.execute("CALL sp_register_shipment(%s, %s)", (shipped, "dhl"))
        c.execute("SAVEPOINT s2")
        with pytest.raises(psycopg.errors.RaiseException):
            c.execute("CALL sp_register_shipment(%s, %s)", (shipped, "dhl"))
        c.execute("ROLLBACK TO SAVEPOINT s2")
        assert c.execute("SELECT COUNT(*) FROM shipments_original WHERE order_id = %s", (shipped,)).fetchone()[0] == 1

def test_mark_shipped_guards():
    # audit finding 10: unknown order raises (never silent no-op); only
    # status='new' is markable
    with _conn() as c:
        c.execute("SAVEPOINT s1")
        with pytest.raises(psycopg.errors.RaiseException):
            c.execute("CALL sp_mark_shipped_new(%s)", (999999,))
        c.execute("ROLLBACK TO SAVEPOINT s1")
        shipped = _new_order(c)
        c.execute("UPDATE orders SET status = 'shipped' WHERE order_id = %s", (shipped,))
        c.execute("SAVEPOINT s2")
        with pytest.raises(psycopg.errors.RaiseException):
            c.execute("CALL sp_mark_shipped_new(%s)", (shipped,))
        c.execute("ROLLBACK TO SAVEPOINT s2")
        assert c.execute("SELECT status FROM orders WHERE order_id = %s", (shipped,)).fetchone()[0] == "shipped"

def test_auth_password_hashed_on_insert_and_update():
    # audit finding 8: plaintext never stored, on INSERT or UPDATE
    with _conn() as c:
        email = f"it-{os.urandom(4).hex()}@example.com"
        c.execute("INSERT INTO AUTH.users (email, password) VALUES (%s, %s)", (email, "hunter2"))
        stored = c.execute("SELECT password FROM AUTH.users WHERE email = %s", (email,)).fetchone()[0]
        assert stored.startswith("$2"), f"insert stored plaintext: {stored[:10]}"
        c.execute("UPDATE AUTH.users SET password = 'hunter3' WHERE email = %s", (email,))
        stored = c.execute("SELECT password FROM AUTH.users WHERE email = %s", (email,)).fetchone()[0]
        assert stored.startswith("$2"), f"update stored plaintext: {stored[:10]}"
        # other-column update must NOT re-hash the hash
        c.execute("UPDATE AUTH.users SET updated_at = NOW() WHERE email = %s", (email,))
        stored2 = c.execute("SELECT password FROM AUTH.users WHERE email = %s", (email,)).fetchone()[0]
        assert stored2 == stored

def test_authz_verify_procedure():
    # audit finding 9: resolves permission through role_permissions and raises
    # on absence (a bare SELECT with no destination previously crashed it)
    with _conn() as c:
        uid = c.execute("INSERT INTO Authz.users (email) VALUES (%s) RETURNING user_id", (f"it-{os.urandom(4).hex()}@example.com",)).fetchone()[0]
        rid = c.execute("INSERT INTO Authz.roles (role_name) VALUES (%s) RETURNING role_id", (f"it-role-{os.urandom(4).hex()}",)).fetchone()[0]
        pid = c.execute("INSERT INTO Authz.permissions (permission_name) VALUES (%s) RETURNING permission_id", (f"it-perm-{os.urandom(4).hex()}",)).fetchone()[0]
        c.execute("INSERT INTO Authz.role_permissions (role_id, permission_id) VALUES (%s, %s)", (rid, pid))
        c.execute("INSERT INTO Authz.user_roles (user_id, role_id) VALUES (%s, %s)", (uid, rid))
        perm = c.execute("SELECT permission_name FROM Authz.permissions WHERE permission_id = %s", (pid,)).fetchone()[0]
        c.execute("CALL Authz.sp_authz_verify(%s, %s)", (uid, perm))   # granted: no raise
        with pytest.raises(psycopg.errors.RaiseException):
            c.execute("CALL Authz.sp_authz_verify(%s, %s)", (uid, "no-such-permission"))

def test_emp_salary_procedure():
    # audit finding 9: renamed parameter (ambiguity) + working body
    with _conn() as c:
        eid = c.execute(
            "INSERT INTO employee.employees (employee_name, employee_email, employee_password) VALUES (%s, %s, %s) RETURNING employee_id",
            (f"it-emp-{os.urandom(4).hex()}", f"it-{os.urandom(4).hex()}@example.com", "x")).fetchone()[0]
        c.execute("CALL Employee.sp_emp_salary(%s)", (eid,))   # exists: no raise
        with pytest.raises(psycopg.errors.RaiseException):
            c.execute("CALL Employee.sp_emp_salary(%s)", (-1,))
