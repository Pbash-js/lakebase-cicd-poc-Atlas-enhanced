-- Add new schema named "test_ce"
CREATE SCHEMA "test_ce";
-- Create "items_test" table
CREATE TABLE "test_ce"."items_test" (
  "id" serial NOT NULL,
  "name" text NOT NULL,
  "is_active" boolean NOT NULL DEFAULT true,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY ("id")
);
-- Create index "idx_items_test_active" to table: "items_test"
CREATE INDEX "idx_items_test_active" ON "test_ce"."items_test" ("is_active");
