-- STATELESS: 05_triggers layer. Trigger function first (CREATE OR REPLACE),
-- then the trigger via DROP IF EXISTS + CREATE: an IF NOT EXISTS guard would
-- silently skip edits to an existing trigger, so edits must recreate it.
CREATE OR REPLACE FUNCTION test_pro.trg_orders_test_touch_fn()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.created_at := NOW();
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_orders_test_touch ON test_pro.orders_test;
CREATE TRIGGER trg_orders_test_touch
BEFORE UPDATE ON test_pro.orders_test
FOR EACH ROW EXECUTE FUNCTION test_pro.trg_orders_test_touch_fn();
