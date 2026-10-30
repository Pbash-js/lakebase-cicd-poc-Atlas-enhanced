-- STATELESS: 02_functions layer. Idempotent replay safe.
CREATE OR REPLACE FUNCTION test_pro.fn_orders_test_total(p_customer_id BIGINT)
RETURNS INTEGER
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(total_cents), 0) FROM test_pro.orders_test WHERE customer_id = p_customer_id;
$$;
