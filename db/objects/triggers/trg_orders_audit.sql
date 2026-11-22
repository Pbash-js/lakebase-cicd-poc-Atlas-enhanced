-- STATELESS: 05_triggers layer. Trigger function first (CREATE OR REPLACE),
-- then the trigger via DROP IF EXISTS + CREATE: an IF NOT EXISTS guard would
-- silently skip edits to an existing trigger, so edits must recreate it.
-- Writes a real audit row (audit finding 13): RAISE NOTICE is invisible
-- outside the session and audits nothing.
CREATE OR REPLACE FUNCTION trg_orders_audit_fn()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO public.audit_log (table_name, row_id, action, changed_by)
    VALUES ('orders', NEW.order_id, TG_OP, current_user);
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_orders_audit ON orders;
CREATE TRIGGER trg_orders_audit
AFTER UPDATE ON orders
FOR EACH ROW EXECUTE FUNCTION trg_orders_audit_fn();
