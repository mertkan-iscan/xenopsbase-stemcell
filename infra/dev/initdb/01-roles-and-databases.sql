-- Mirrors what CloudNativePG's managed roles give the deployed cluster
-- (platform/envs/dev/database/cluster.yaml). Without it the services connect as
-- roles that do not exist and Flyway fails with:
--
--   PSQLException: FATAL: role "core" does not exist
--
-- which names the role but not the fact that the CLUSTER creates it and a plain
-- postgres image does not.
CREATE ROLE core LOGIN PASSWORD 'core';
ALTER DATABASE core OWNER TO core;
GRANT ALL PRIVILEGES ON DATABASE core TO core;

-- Keycloak needs its own database on the same server, exactly as the deployed
-- cluster gives it one. Without this Keycloak starts, fails to connect, and
-- retries forever while the container still reports "running".
CREATE DATABASE keycloak;
