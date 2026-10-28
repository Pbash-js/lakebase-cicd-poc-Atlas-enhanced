-- Add new schema named "new_shared_schema"
CREATE SCHEMA "new_shared_schema";
-- Create index "idx_customers_name" to table: "customers"
CREATE UNIQUE INDEX "idx_customers_name" ON "public"."customers" ("name");
-- Modify "orders" table
ALTER TABLE "public"."orders" ADD COLUMN "currency" text NOT NULL DEFAULT 'INR';
-- Rename a table from "shipments" to "shipments_original"
ALTER TABLE "public"."shipments" RENAME TO "shipments_original";
-- Rename a constraint from "shipments_pkey" to "shipments_original_pkey"
ALTER TABLE "public"."shipments_original" RENAME CONSTRAINT "shipments_pkey" TO "shipments_original_pkey";
-- Modify "shipments_original" table
ALTER TABLE "public"."shipments_original" DROP CONSTRAINT "shipments_order_id_fkey", ALTER COLUMN "priority" SET DEFAULT 3, ADD CONSTRAINT "shipments_original_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders" ("order_id") ON UPDATE NO ACTION ON DELETE NO ACTION;
-- Create index "idx_shipments_order" to table: "shipments_original"
CREATE INDEX "idx_shipments_order" ON "public"."shipments_original" ("order_id");
-- Create "shipments_shared" table
CREATE TABLE "new_shared_schema"."shipments_shared" (
  "shipment_id" bigint NOT NULL GENERATED ALWAYS AS IDENTITY,
  "order_id" bigint NOT NULL,
  "carrier" text NOT NULL DEFAULT 'blue-dart',
  "status" text NOT NULL DEFAULT 'pending',
  "shipped_at" timestamptz NULL,
  "priority" integer NOT NULL DEFAULT 5,
  PRIMARY KEY ("shipment_id"),
  CONSTRAINT "shipments_shared_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders" ("order_id") ON UPDATE NO ACTION ON DELETE NO ACTION
);
