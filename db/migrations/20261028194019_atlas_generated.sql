-- Add new schema named "authz"
CREATE SCHEMA "authz";
-- Add new schema named "employee"
CREATE SCHEMA "employee";
-- Add new schema named "employee_data"
CREATE SCHEMA "employee_data";
-- Create "employees" table
CREATE TABLE "employee"."employees" (
  "employee_id" serial NOT NULL,
  "employee_name" text NOT NULL,
  "employee_email" text NOT NULL,
  "employee_password" text NOT NULL,
  "employee_created_at" timestamptz NOT NULL DEFAULT now(),
  "employee_updated_at" timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY ("employee_id"),
  CONSTRAINT "employees_employee_email_key" UNIQUE ("employee_email")
);
-- Create "employee_details" table
CREATE TABLE "employee_data"."employee_details" (
  "employee_id" integer NOT NULL,
  "employee_details_name" text NOT NULL,
  "employee_details_email" text NOT NULL,
  "employee_details_password" text NOT NULL,
  "employee_details_created_at" timestamptz NOT NULL DEFAULT now(),
  "employee_details_updated_at" timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY ("employee_id"),
  CONSTRAINT "employee_details_employee_details_email_key" UNIQUE ("employee_details_email"),
  CONSTRAINT "employee_details_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "employee"."employees" ("employee_id") ON UPDATE NO ACTION ON DELETE NO ACTION
);
-- Create "permissions" table
CREATE TABLE "authz"."permissions" (
  "permission_id" serial NOT NULL,
  "permission_name" text NOT NULL,
  PRIMARY KEY ("permission_id"),
  CONSTRAINT "permissions_permission_name_key" UNIQUE ("permission_name")
);
-- Create "roles" table
CREATE TABLE "authz"."roles" (
  "role_id" serial NOT NULL,
  "role_name" text NOT NULL,
  PRIMARY KEY ("role_id"),
  CONSTRAINT "roles_role_name_key" UNIQUE ("role_name")
);
-- Create "role_permissions" table
CREATE TABLE "authz"."role_permissions" (
  "role_id" integer NOT NULL,
  "permission_id" integer NOT NULL,
  PRIMARY KEY ("role_id", "permission_id"),
  CONSTRAINT "role_permissions_permission_id_fkey" FOREIGN KEY ("permission_id") REFERENCES "authz"."permissions" ("permission_id") ON UPDATE NO ACTION ON DELETE NO ACTION,
  CONSTRAINT "role_permissions_role_id_fkey" FOREIGN KEY ("role_id") REFERENCES "authz"."roles" ("role_id") ON UPDATE NO ACTION ON DELETE NO ACTION
);
-- Create "users" table
CREATE TABLE "authz"."users" (
  "user_id" serial NOT NULL,
  "email" text NOT NULL,
  PRIMARY KEY ("user_id"),
  CONSTRAINT "users_email_key" UNIQUE ("email")
);
-- Create "user_roles" table
CREATE TABLE "authz"."user_roles" (
  "user_id" integer NOT NULL,
  "role_id" integer NOT NULL,
  PRIMARY KEY ("user_id", "role_id"),
  CONSTRAINT "user_roles_role_id_fkey" FOREIGN KEY ("role_id") REFERENCES "authz"."roles" ("role_id") ON UPDATE NO ACTION ON DELETE NO ACTION,
  CONSTRAINT "user_roles_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "authz"."users" ("user_id") ON UPDATE NO ACTION ON DELETE NO ACTION
);
