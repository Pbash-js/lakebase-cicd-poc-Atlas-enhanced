CREATE OR REPLACE FUNCTION AUTH.fn_auth_entry()
RETURNS TRIGGER AS $$
BEGIN
    -- INSERT: always hash. UPDATE: hash only when the password actually
    -- changed, otherwise other column updates would re-hash the hash.
    IF TG_OP = 'INSERT' OR NEW.password IS DISTINCT FROM OLD.password THEN
        NEW.password = crypt(NEW.password, gen_salt('bf'));
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
