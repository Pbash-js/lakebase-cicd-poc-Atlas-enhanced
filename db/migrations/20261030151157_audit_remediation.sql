-- Modify "users" table
-- Rename preserves the identity values (audit finding 14): the PK column
-- was misnamed shipment_id (copy-paste from AMSShared). ATLAS plans DROP+ADD
-- for renames; hand-edited to RENAME COLUMN, values kept.
ALTER TABLE "auth"."users" RENAME COLUMN "shipment_id" TO "user_id";
-- Create "audit_log" table
CREATE TABLE "public"."audit_log" (
  "audit_id" bigint NOT NULL GENERATED ALWAYS AS IDENTITY,
  "table_name" text NOT NULL,
  "row_id" bigint NOT NULL,
  "action" text NOT NULL,
  "changed_by" text NOT NULL DEFAULT CURRENT_USER,
  "changed_at" timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY ("audit_id")
);
-- Create index "idx_audit_log_table_row" to table: "audit_log"
CREATE INDEX "idx_audit_log_table_row" ON "public"."audit_log" ("table_name", "row_id");
-- Drop enum type "order_status"
DROP TYPE "public"."order_status";
