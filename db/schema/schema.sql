-- Desired state: single declarative SQL file. The Atlas source of truth
-- for structural schema (tables, columns, indexes, constraints, enums).
-- Code objects (functions, procedures, views, triggers) live in db/objects.

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
    note        TEXT NOT NULL DEFAULT '',
    tag         TEXT NOT NULL DEFAULT '',
    currency    TEXT NOT NULL DEFAULT 'INR'
);
CREATE INDEX idx_orders_customer ON orders (customer_id);

-- atlas:renamed_from shipments
CREATE TABLE shipments_original (
    shipment_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id    BIGINT NOT NULL REFERENCES orders(order_id),
    carrier     TEXT NOT NULL DEFAULT 'blue-dart',
    status      TEXT NOT NULL DEFAULT 'pending',
    shipped_at  TIMESTAMPTZ,
    priority    INTEGER NOT NULL DEFAULT 3
);
CREATE UNIQUE INDEX idx_customers_name ON customers (name);
CREATE INDEX idx_shipments_order ON shipments_original (order_id);

CREATE TABLE audit_log (
    audit_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    table_name TEXT NOT NULL,
    row_id     BIGINT NOT NULL,
    action     TEXT NOT NULL,
    changed_by TEXT NOT NULL DEFAULT current_user,
    changed_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_audit_log_table_row ON audit_log (table_name, row_id);
