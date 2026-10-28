CREATE OR REPLACE TRIGGER trg_emp_data_v2
BEFORE INSERT ON employee_data.employee_details
FOR EACH ROW
EXECUTE FUNCTION employee_data.fn_emp_data_insert();