CREATE SCHEMA IF NOT EXISTS test_ce;

CREATE TABLE test_ce.items_test (
    id          SERIAL PRIMARY KEY,
    name        TEXT NOT NULL,
    is_active   BOOLEAN NOT NULL DEFAULT TRUE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_items_test_active ON test_ce.items_test (is_active);
