-- STATELESS: 03_procedures layer. Inserts one demo note; empty bodies refused.
CREATE OR REPLACE PROCEDURE sp_add_demo_note(p_body TEXT)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_body IS NULL OR btrim(p_body) = '' THEN
        RAISE EXCEPTION 'demo note body must not be empty';
    END IF;
    INSERT INTO demo_notes (body) VALUES (btrim(p_body));
END $$;
