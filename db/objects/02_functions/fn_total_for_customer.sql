-- STATELESS: 02_functions layer. Idempotent replay safe.
CREATE OR REPLACE FUNCTION fn_total_for_customer(p_customer_id BIGINT)
RETURNS INTEGER
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(total_cents), 0) FROM orders WHERE customer_id = p_customer_id;
$$;
