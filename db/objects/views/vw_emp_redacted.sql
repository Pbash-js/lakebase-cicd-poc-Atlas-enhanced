CREATE OR REPLACE VIEW employee.vw_emp_redacted AS
SELECT employee_id, employee_email, employee_created_at, employee_updated_at, 'REDACTED' AS employee_password
FROM employee.employees;