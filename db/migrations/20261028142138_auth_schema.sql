-- Create extension "pgcrypto"
CREATE EXTENSION "pgcrypto" WITH SCHEMA "public" VERSION "1.3";
-- Add new schema named "auth"
CREATE SCHEMA "auth";
-- Create "users" table
CREATE TABLE "auth"."users" (
  "shipment_id" bigint NOT NULL GENERATED ALWAYS AS IDENTITY,
  "email" text NOT NULL,
  "password" text NOT NULL,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  "updated_at" timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY ("shipment_id"),
  CONSTRAINT "users_email_key" UNIQUE ("email")
);
