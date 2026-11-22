-- STATELESS: 05_triggers layer. Audit trigger on shipments.
-- Trigger via DROP IF EXISTS + CREATE: an IF NOT EXISTS guard would
-- silently skip edits to an existing trigger, so edits must recreate it.
-- Writes a real audit row (audit finding 13): RAISE NOTICE is invisible
-- outside the session and audits nothing.
CREATE OR REPLACE FUNCTION trg_shipments_audit_fn()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO public.audit_log (table_name, row_id, action, changed_by)
    VALUES ('shipments_original', NEW.shipment_id, TG_OP, current_user);
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_shipments_audit ON shipments_original;
CREATE TRIGGER trg_shipments_audit
AFTER INSERT OR UPDATE ON shipments_original
FOR EACH ROW EXECUTE FUNCTION trg_shipments_audit_fn();
