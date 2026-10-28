CREATE OR REPLACE PROCEDURE Authz.sp_authz_verify(
    IN p_user_id INT,
    IN p_permission_name TEXT
)
AS $$
BEGIN
    SELECT * FROM Authz.user_roles
    WHERE user_id = p_user_id
    AND role_id IN (SELECT role_id FROM Authz.roles WHERE role_name = p_permission_name);
END;
$$ LANGUAGE plpgsql;