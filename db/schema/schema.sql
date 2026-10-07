-- Desired state: single declarative SQL file. The Atlas source of truth
-- for structural schema (tables, columns, indexes, constraints, enums).
-- Code objects (functions, procedures, views, triggers) live in db/objects.
CREATE TYPE order_status AS ENUM ('new', 'shipped', 'cancelled');

CREATE TABLE customers (
    customer_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name        TEXT NOT NULL,
    status      TEXT NOT NULL DEFAULT 'active',
    region      TEXT NOT NULL DEFAULT 'global'
);

CREATE TABLE orders (
    order_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id BIGINT NOT NULL REFERENCES customers(customer_id),
    status      TEXT NOT NULL DEFAULT 'new',
    total_cents BIGINT NOT NULL DEFAULT 0,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    note        TEXT NOT NULL DEFAULT ''
);
CREATE INDEX idx_orders_customer ON orders (customer_id);

CREATE TABLE shipments (
    shipment_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id    BIGINT NOT NULL REFERENCES orders(order_id),
    carrier     TEXT NOT NULL DEFAULT 'blue-dart',
    status      TEXT NOT NULL DEFAULT 'pending',
    shipped_at  TIMESTAMPTZ,
    priority    INTEGER NOT NULL DEFAULT 5
);
