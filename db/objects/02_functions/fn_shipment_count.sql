-- STATELESS: 02_functions layer. Idempotent replay safe.
CREATE OR REPLACE FUNCTION fn_shipment_count(p_order_id BIGINT)
RETURNS INTEGER
LANGUAGE sql STABLE AS $$
    SELECT COUNT(*)::INTEGER FROM shipments_original WHERE order_id = p_order_id;
$$;
