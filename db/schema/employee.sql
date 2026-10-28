CREATE SCHEMA IF NOT EXISTS employee;

CREATE SCHEMA IF NOT EXISTS employee_data;

CREATE TABLE employee.employees (
    employee_id SERIAL PRIMARY KEY,
    employee_name TEXT NOT NULL,
    employee_email TEXT NOT NULL UNIQUE,
    employee_password TEXT NOT NULL,
    employee_created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    employee_updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE employee_data.employee_details (
    employee_id INT PRIMARY KEY REFERENCES employee.employees(employee_id),
    employee_details_name TEXT NOT NULL,
    employee_details_email TEXT NOT NULL UNIQUE,
    employee_details_password TEXT NOT NULL,
    employee_details_created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    employee_details_updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);