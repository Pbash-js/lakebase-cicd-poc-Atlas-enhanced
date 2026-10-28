CREATE OR REPLACE FUNCTION employee_data.fn_emp_data_insert()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO employee_data.employee_details (employee_id, employee_details_name, employee_details_email, employee_details_password)
    VALUES (NEW.employee_id, NEW.employee_details_name, NEW.employee_details_email, NEW.employee_details_password);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;