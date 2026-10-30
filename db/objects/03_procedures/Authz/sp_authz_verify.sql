-- STATELESS: 03_procedures layer. Verifies a user holds a permission
-- (user -> role -> role_permissions -> permissions). Raises on absence so a
-- caller can treat the CALL as the authorization check.
CREATE OR REPLACE PROCEDURE Authz.sp_authz_verify(
    IN p_user_id INT,
    IN p_permission_name TEXT
)
AS $$
DECLARE
    v_count INT;
BEGIN
    SELECT COUNT(*) INTO v_count
    FROM Authz.user_roles ur
    JOIN Authz.role_permissions rp ON rp.role_id = ur.role_id
    JOIN Authz.permissions p ON p.permission_id = rp.permission_id
    WHERE ur.user_id = p_user_id
      AND p.permission_name = p_permission_name;
    IF v_count IS NULL OR v_count = 0 THEN
        RAISE EXCEPTION 'user % lacks permission %', p_user_id, p_permission_name;
    END IF;
END;
$$ LANGUAGE plpgsql;