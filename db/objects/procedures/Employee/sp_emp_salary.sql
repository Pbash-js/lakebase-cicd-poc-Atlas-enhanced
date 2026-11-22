-- STATELESS: 03_procedures layer. Parameter renamed to p_employee_id: a
-- parameter named like the column makes every column reference ambiguous.
CREATE OR REPLACE PROCEDURE Employee.sp_emp_salary(p_employee_id INT)
AS $$
DECLARE
    v_count INT;
BEGIN
    SELECT COUNT(*) INTO v_count FROM employee.employees
    WHERE employees.employee_id = p_employee_id;
    IF v_count = 0 THEN
        RAISE EXCEPTION 'employee % not found', p_employee_id;
    END IF;
    PERFORM employee_id, employee_name, employee_email FROM employee.employees
    WHERE employees.employee_id = p_employee_id;
END;
$$ LANGUAGE plpgsql;