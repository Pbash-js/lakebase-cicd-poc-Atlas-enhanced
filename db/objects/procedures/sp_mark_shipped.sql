-- STATELESS: 03_procedures layer. Marks an order shipped. Guards: the order
-- must exist and be in 'new'; a missing row raises, never silently ignored.
CREATE OR REPLACE PROCEDURE sp_mark_shipped_new(p_order_id BIGINT)
LANGUAGE plpgsql AS $$
DECLARE
    v_status TEXT;
BEGIN
    SELECT status INTO v_status FROM orders WHERE order_id = p_order_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'order % not found', p_order_id;
    END IF;
    IF v_status <> 'new' THEN
        RAISE EXCEPTION 'order % is %, expected new', p_order_id, v_status;
    END IF;
    UPDATE orders SET status = 'shipped' WHERE order_id = p_order_id;
END $$;
