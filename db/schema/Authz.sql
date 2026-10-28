CREATE SCHEMA IF NOT EXISTS Authz;

-- ponytail: minimal shapes to satisfy the FKs + sp_authz_verify; extend freely
CREATE TABLE Authz.users (
    user_id SERIAL PRIMARY KEY,
    email TEXT NOT NULL UNIQUE
);

CREATE TABLE Authz.permissions (
    permission_id SERIAL PRIMARY KEY,
    permission_name TEXT NOT NULL UNIQUE
);

CREATE TABLE Authz.roles (
    role_id SERIAL PRIMARY KEY,
    role_name TEXT NOT NULL UNIQUE
);

CREATE TABLE Authz.role_permissions (
    role_id INT NOT NULL REFERENCES Authz.roles(role_id),
    permission_id INT NOT NULL REFERENCES Authz.permissions(permission_id),
    PRIMARY KEY (role_id, permission_id)
);

CREATE TABLE Authz.user_roles (
    user_id INT NOT NULL REFERENCES Authz.users(user_id),
    role_id INT NOT NULL REFERENCES Authz.roles(role_id),
    PRIMARY KEY (user_id, role_id)
);