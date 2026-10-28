CREATE OR REPLACE PROCEDURE Employee.sp_emp_salary(employee_id INT)
AS $$
BEGIN
    SELECT * FROM employee.employees
    WHERE employee_id = employee_id;
END;
$$ LANGUAGE plpgsql;