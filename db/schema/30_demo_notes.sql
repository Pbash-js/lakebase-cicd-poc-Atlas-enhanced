-- Demo smoke change: one table exercising the full Atlas Pro pipeline.
CREATE TABLE demo_notes (
    note_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    body       TEXT NOT NULL,
    author     TEXT NOT NULL DEFAULT 'pipeline-smoke',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
