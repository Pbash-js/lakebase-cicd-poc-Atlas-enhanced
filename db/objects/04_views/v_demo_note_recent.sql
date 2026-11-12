-- STATELESS: 04_views layer. Latest 10 demo notes (dependent on demo_notes).
CREATE OR REPLACE VIEW v_demo_note_recent AS
SELECT note_id, body, author, created_at
FROM demo_notes
ORDER BY created_at DESC, note_id DESC
LIMIT 10;
