-- STATELESS: 02_functions layer. Idempotent replay safe.
CREATE OR REPLACE FUNCTION test_ce.fn_items_test_count(p_active BOOLEAN)
RETURNS BIGINT
LANGUAGE sql STABLE AS $$
    SELECT COUNT(*) FROM test_ce.items_test WHERE is_active = p_active;
$$;
