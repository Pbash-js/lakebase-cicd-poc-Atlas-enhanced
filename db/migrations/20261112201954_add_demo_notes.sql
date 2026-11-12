-- Create "demo_notes" table
CREATE TABLE "public"."demo_notes" (
  "note_id" bigint NOT NULL GENERATED ALWAYS AS IDENTITY,
  "body" text NOT NULL,
  "author" text NOT NULL DEFAULT 'pipeline-smoke',
  "created_at" timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY ("note_id")
);
