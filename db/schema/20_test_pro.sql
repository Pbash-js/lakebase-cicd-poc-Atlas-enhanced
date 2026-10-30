CREATE SCHEMA IF NOT EXISTS test_pro;

CREATE TABLE test_pro.orders_test (
    id          SERIAL PRIMARY KEY,
    customer_id BIGINT NOT NULL,
    total_cents INTEGER NOT NULL DEFAULT 0,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_orders_test_customer ON test_pro.orders_test (customer_id);
