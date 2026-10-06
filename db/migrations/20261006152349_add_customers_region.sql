-- Modify "customers" table
ALTER TABLE "public"."customers" ADD COLUMN "region" text NOT NULL DEFAULT 'global';
