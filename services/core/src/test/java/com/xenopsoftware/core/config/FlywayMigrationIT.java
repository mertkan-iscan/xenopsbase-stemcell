package com.xenopsoftware.core.config;

import static org.assertj.core.api.Assertions.assertThat;

import com.xenopsoftware.core.IntegrationTest;
import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;
import java.util.stream.Stream;
import javax.sql.DataSource;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.jdbc.core.JdbcTemplate;

/**
 * That the migrations ran, all of them, on a database that started empty (T-5.3).
 *
 * <h2>Why assert something that already happens</h2>
 *
 * Flyway runs before the context starts and {@code ddl-auto: validate} fails startup if the schema
 * does not match the entities, so a broken migration already breaks every other integration test.
 * That is real coverage and it is coverage of the wrong thing: it proves the schema Hibernate
 * needs exists, not that the migrations this repository ships are what produced it.
 *
 * <p>The difference shows up in the cases that matter. A migration whose file was renamed, one
 * that was applied out of order, or one that succeeded on a database somebody had already touched
 * are all invisible to {@code validate} and all visible here.
 *
 * <h2>Clean, and what that word is doing</h2>
 *
 * The acceptance criterion is "against a clean database in CI on every build", which is a claim
 * about the container rather than about Flyway. {@code DatabaseTestcontainer} asks for reuse, and
 * reuse only happens when {@code testcontainers.reuse.enable=true} is set in a developer's
 * {@code ~/.testcontainers.properties} — never on a CI runner, which has no such file. So CI gets
 * a fresh Postgres and this asserts that the fresh one really was fresh: a reused database would
 * show migrations installed by an earlier run, with timestamps and an install order that no longer
 * start at the baseline.
 */
@IntegrationTest
class FlywayMigrationIT {

    @Autowired
    private DataSource dataSource;

    @Test
    @DisplayName("every committed migration was applied, in order, and none failed")
    void everyMigrationIsRecordedAsSuccessful() {
        JdbcTemplate jdbc = new JdbcTemplate(dataSource);

        List<Map<String, Object>> history = jdbc.queryForList(
            "select version, description, success, installed_rank from flyway_schema_history where type <> 'SCHEMA' order by installed_rank"
        );

        assertThat(history).as("flyway_schema_history is empty, so nothing migrated this database").isNotEmpty();

        assertThat(history)
            .as("a failed migration leaves a row behind with success = false")
            .allSatisfy(row -> assertThat(row.get("success")).isEqualTo(Boolean.TRUE));

        List<String> applied = history.stream().map(row -> String.valueOf(row.get("version"))).toList();

        // The committed files, read from disk rather than listed here. A list in this file would
        // have to be updated by whoever adds a migration, and the one thing certain about such a
        // list is that it will one day not be.
        List<String> committed = committedMigrationVersions();

        // Without this the whole comparison below is vacuous: a wrong path returns an empty list
        // and `containsAll(emptyList)` is true of anything. The same shape passed for four of five
        // assertions in the T-5.2 security slice, so it is worth one line to make impossible.
        assertThat(committed).as("no migration files were found, so the comparison below proves nothing").isNotEmpty();

        assertThat(applied)
            .as("the migrations on disk and the migrations in the database disagree")
            .containsAll(committed);

        // Ordering, not just membership. Flyway applies by version, and a database that received
        // them in a different order is one where an earlier migration saw a later schema.
        List<String> appliedProduction = applied.stream().filter(committed::contains).toList();
        assertThat(appliedProduction).as("migrations were applied out of version order").isSorted();
    }

    @Test
    @DisplayName("the database started empty, so the baseline is the first thing that ran")
    void theDatabaseWasCleanBeforeTheMigrations() {
        JdbcTemplate jdbc = new JdbcTemplate(dataSource);

        String firstApplied = jdbc.queryForObject(
            "select version from flyway_schema_history where type <> 'SCHEMA' order by installed_rank limit 1",
            String.class
        );

        // V1 is the baseline. Anything else first means Flyway found a schema it did not create,
        // which on a test container means the container was reused with state from an earlier run
        // — and a migration suite that only ever runs against an already-migrated database is not
        // being tested at all.
        assertThat(firstApplied).as("the first migration applied was not the baseline, so the database was not clean").isEqualTo("1");

        Integer repeats = jdbc.queryForObject(
            "select count(*) from (select version from flyway_schema_history where type <> 'SCHEMA' group by version having count(*) > 1) duplicated",
            Integer.class
        );
        assertThat(repeats).as("a version appears twice in the history").isZero();
    }

    /** Versions parsed from the committed {@code V<n>__name.sql} files. */
    private static List<String> committedMigrationVersions() {
        Path migrations = repositoryRoot().resolve("services/core/src/main/resources/db/migration");
        try (Stream<Path> files = Files.list(migrations)) {
            return files
                .map(path -> path.getFileName().toString())
                .filter(name -> name.startsWith("V") && name.endsWith(".sql"))
                .map(name -> name.substring(1, name.indexOf("__")))
                .sorted()
                .toList();
        } catch (IOException e) {
            throw new UncheckedIOException("could not list " + migrations, e);
        }
    }

    /** Same walk-up as the container harnesses use, and for the same reason. */
    private static Path repositoryRoot() {
        Path candidate = Path.of("").toAbsolutePath();
        while (candidate != null && !Files.isDirectory(candidate.resolve("platform"))) {
            candidate = candidate.getParent();
        }
        if (candidate == null) {
            throw new IllegalStateException("could not locate the repository root from " + Path.of("").toAbsolutePath());
        }
        return candidate;
    }
}
