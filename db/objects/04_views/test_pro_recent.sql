-- STATELESS: 04_views layer. CREATE OR REPLACE VIEW is idempotent.
CREATE OR REPLACE VIEW test_pro.v_orders_test_recent AS
SELECT id, customer_id, total_cents, created_at
FROM test_pro.orders_test
WHERE created_at >= NOW() - INTERVAL '7 days';
