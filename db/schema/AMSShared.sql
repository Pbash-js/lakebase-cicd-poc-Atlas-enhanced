-- STATELESS base schema file: applied AFTER schema.sql (build order: schema.sql first, then *.sql sorted).
CREATE SCHEMA IF NOT EXISTS new_shared_schema;

CREATE TABLE new_shared_schema.shipments_shared (
    shipment_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id    BIGINT NOT NULL REFERENCES orders(order_id),
    carrier     TEXT NOT NULL DEFAULT 'blue-dart',
    status      TEXT NOT NULL DEFAULT 'pending',
    shipped_at  TIMESTAMPTZ,
    priority    INTEGER NOT NULL DEFAULT 5
);