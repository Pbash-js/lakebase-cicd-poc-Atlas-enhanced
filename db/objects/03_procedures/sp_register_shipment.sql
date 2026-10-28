-- STATELESS: 03_procedures layer. Stored procedure to register a shipment and mark the order shipped.
CREATE OR REPLACE PROCEDURE sp_register_shipment(p_order_id BIGINT, p_carrier TEXT)
LANGUAGE plpgsql AS $$
DECLARE
    v_customer BIGINT;
BEGIN
    SELECT customer_id INTO v_customer FROM orders WHERE order_id = p_order_id;
    IF v_customer IS NULL THEN
        RAISE EXCEPTION 'order % not found', p_order_id;
    END IF;
    INSERT INTO shipments_original (order_id, carrier, status, shipped_at)
    VALUES (p_order_id, p_carrier, 'in-transit', now());
    UPDATE orders SET status = 'shipped' WHERE order_id = p_order_id;
END $$;
