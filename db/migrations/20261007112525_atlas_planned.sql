-- Modify "orders" table
ALTER TABLE "public"."orders" ADD COLUMN "tag" text NOT NULL DEFAULT '';
