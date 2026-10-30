-- STATELESS: 04_views layer. CREATE OR REPLACE VIEW is idempotent.
-- Pure aggregation (audit finding 14): no per-row function calls, so the
-- view is one scan of orders regardless of customer count.
CREATE OR REPLACE VIEW v_order_totals AS
SELECT c.customer_id,
       c.name,
       COUNT(o.order_id)               AS order_count,
       COALESCE(SUM(o.total_cents), 0) AS total_cents
FROM customers c
LEFT JOIN orders o ON o.customer_id = c.customer_id
GROUP BY c.customer_id, c.name;
