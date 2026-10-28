-- STATELESS: 03_procedures layer. Runtime-resolved deps — no ordering constraint within the layer.
CREATE OR REPLACE PROCEDURE sp_mark_shipped_new(p_order_id BIGINT)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE orders SET status = 'shipped' WHERE order_id = p_order_id;
END $$;
