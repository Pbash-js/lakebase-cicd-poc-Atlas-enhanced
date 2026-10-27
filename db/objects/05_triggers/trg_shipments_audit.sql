-- STATELESS: 05_triggers layer. Audit trigger on shipments.
-- Trigger via DROP IF EXISTS + CREATE: an IF NOT EXISTS guard would
-- silently skip edits to an existing trigger, so edits must recreate it.
CREATE OR REPLACE FUNCTION trg_shipments_audit_fn()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE NOTICE 'shipment % for order % -> %', NEW.shipment_id, NEW.order_id, NEW.status;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_shipments_audit ON shipments;
CREATE TRIGGER trg_shipments_audit
AFTER INSERT OR UPDATE ON shipments
FOR EACH ROW EXECUTE FUNCTION trg_shipments_audit_fn();
