-- STATELESS: 04_views layer. CREATE OR REPLACE VIEW is idempotent.
CREATE OR REPLACE VIEW test_ce.v_items_test_active AS
SELECT id, name, created_at
FROM test_ce.items_test
WHERE is_active;
