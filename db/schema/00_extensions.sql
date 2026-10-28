-- STATELESS: extensions used by db/objects (pgcrypto: crypt/gen_salt for
-- auth password hashing). Declared here so the Pro declarative diff plans
-- it; IF NOT EXISTS keeps the replay idempotent.
CREATE EXTENSION IF NOT EXISTS pgcrypto;
