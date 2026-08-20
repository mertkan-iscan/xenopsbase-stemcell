-- V900 — schema for test-only entities. TEST CLASSPATH ONLY.
--
-- This file is under src/test/resources, so it is never packaged and never runs
-- against a real database. It is reachable only because the test configuration
-- adds classpath:db/testmigration to spring.flyway.locations.
--
-- Why it exists: HibernateTimeZoneIT maps a DateTimeWrapper entity that has no
-- home in the application schema, because it is not part of the application. It
-- exists to prove that Hibernate reads and writes java.time values against a
-- real Postgres in the configured timezone, which is worth knowing and cannot
-- be tested without a table.
--
-- Before this file, the generator's answer was to turn schema validation off in
-- the test profiles (ddl-auto: none). That bought a passing build at the cost of
-- the one guarantee the test suite should provide: that entities and migrations
-- agree. Giving the test entity a migration instead lets the test profiles run
-- ddl-auto: validate like every deployed profile, so entity drift fails here
-- rather than at a deployment.
--
-- Numbered 900 to stay clear of the application's own sequence. Real migrations
-- count up from 1; if they ever reach 900, renumber this rather than the ones
-- that have already been applied somewhere.

-- Every column is deliberately WITHOUT time zone. That is the whole point of the
-- test: with hibernate.jdbc.time_zone=UTC, Hibernate must normalise an Instant,
-- OffsetDateTime or ZonedDateTime to UTC before it reaches the column, and a
-- zone-less column is the only way to observe whether it actually did.
--
-- timestamptz would make the test pass or fail depending on the session
-- timezone: Postgres stores UTC internally but renders it in the session's zone
-- on read, so the assertions come back shifted by whatever offset the machine
-- happens to be in. Which is a real trap -- it looks like a Hibernate bug.
CREATE TABLE jhi_date_time_wrapper (
    id               bigint PRIMARY KEY,
    instant          timestamp,
    local_date_time  timestamp,
    offset_date_time timestamp,
    zoned_date_time  timestamp,
    local_time       time,
    offset_time      time,
    local_date       date
);

-- The entity uses GenerationType.SEQUENCE with the default generator name,
-- which Hibernate resolves to a sequence literally called sequence_generator.
CREATE SEQUENCE sequence_generator START WITH 1050 INCREMENT BY 50;
