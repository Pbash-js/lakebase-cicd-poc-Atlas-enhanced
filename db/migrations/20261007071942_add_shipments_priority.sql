-- Modify "shipments" table
ALTER TABLE "public"."shipments" ADD COLUMN "priority" integer NOT NULL DEFAULT 5;
