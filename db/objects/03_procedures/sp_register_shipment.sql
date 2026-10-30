-- STATELESS: 03_procedures layer. Registers a shipment and marks the order
-- shipped. Locks the order row (FOR UPDATE), requires status 'new' (cancelled
-- and already-shipped orders are refused), inserts the shipment, then marks
-- shipped through sp_mark_shipped_new so both paths enforce the same guards.
CREATE OR REPLACE PROCEDURE sp_register_shipment(p_order_id BIGINT, p_carrier TEXT)
LANGUAGE plpgsql AS $$
DECLARE
    v_customer BIGINT;
    v_status TEXT;
BEGIN
    SELECT customer_id, status INTO v_customer, v_status
    FROM orders WHERE order_id = p_order_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'order % not found', p_order_id;
    END IF;
    IF v_status <> 'new' THEN
        RAISE EXCEPTION 'order % is %, cannot register a shipment', p_order_id, v_status;
    END IF;
    INSERT INTO shipments_original (order_id, carrier, status, shipped_at)
    VALUES (p_order_id, p_carrier, 'in-transit', now());
    CALL sp_mark_shipped_new(p_order_id);
END $$;
