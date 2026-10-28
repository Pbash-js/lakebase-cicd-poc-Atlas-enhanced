CREATE OR REPLACE VIEW dep_test_view AS
SELECT email, password, created_at, CURRENT_TIMESTAMP AS updated_at FROM AUTH.users;