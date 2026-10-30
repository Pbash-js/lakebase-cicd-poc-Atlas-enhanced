-- Add new schema named "test_pro"
CREATE SCHEMA "test_pro";
-- Create "orders_test" table
CREATE TABLE "test_pro"."orders_test" (
  "id" serial NOT NULL,
  "customer_id" bigint NOT NULL,
  "total_cents" integer NOT NULL DEFAULT 0,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY ("id")
);
-- Create index "idx_orders_test_customer" to table: "orders_test"
CREATE INDEX "idx_orders_test_customer" ON "test_pro"."orders_test" ("customer_id");
