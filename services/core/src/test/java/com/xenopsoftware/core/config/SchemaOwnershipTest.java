package com.xenopsoftware.core.config;

import static org.assertj.core.api.Assertions.assertThat;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Properties;
import java.util.Set;
import java.util.stream.Stream;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.config.YamlPropertiesFactoryBean;
import org.springframework.core.io.FileSystemResource;

/**
 * Guards the schema-ownership rule: Flyway owns the schema, Hibernate only ever reads it.
 *
 * <p>This is a static scan of every configuration file rather than a runtime check, on purpose.
 * A runtime assertion only covers the profile the test happens to activate, so a dangerous value
 * in a profile no test exercises — {@code prod} being the obvious one — would sail through. The
 * mistake being guarded against is an edit to a YAML file, so the guard reads the YAML files.
 *
 * <p>The forbidden values are the ones that let Hibernate issue DDL: {@code update},
 * {@code create}, {@code create-drop} and {@code create-only}. Any of those turns the running
 * application into a second, unversioned schema author, which is precisely the no-rollback gap
 * this template exists to avoid.
 */
class SchemaOwnershipTest {

    /** Both spellings matter: Spring's relaxed key and the raw Hibernate property. */
    private static final Set<String> DDL_AUTO_KEYS = Set.of(
        "spring.jpa.hibernate.ddl-auto",
        "spring.jpa.properties.hibernate.hbm2ddl.auto"
    );

    /** {@code validate} checks the schema; {@code none} skips the check. Neither writes. */
    private static final Set<String> READ_ONLY_VALUES = Set.of("validate", "none");

    private static final Path MAIN_CONFIG = Path.of("src/main/resources/config");
    private static final Path TEST_CONFIG = Path.of("src/test/resources/config");

    @Test
    void noConfigurationFileLetsHibernateWriteToTheSchema() {
        List<Path> files = configFiles();
        assertThat(files).as("configuration files to scan — an empty scan would pass vacuously").isNotEmpty();

        for (Path file : files) {
            Properties properties = flatten(file);
            for (String key : DDL_AUTO_KEYS) {
                String value = properties.getProperty(key);
                if (value != null) {
                    assertThat(value.trim())
                        .as("%s sets %s — Flyway owns the schema, so Hibernate must not write to it", file, key)
                        .isIn(READ_ONLY_VALUES);
                }
            }
        }
    }

    @Test
    void theApplicationValidatesTheFlywayOwnedSchemaOnStartup() {
        assertThat(flatten(MAIN_CONFIG.resolve("application.yml")).getProperty("spring.jpa.hibernate.ddl-auto"))
            .as("the shared configuration must validate, so a drifted entity fails at startup rather than at first query")
            .isEqualTo("validate");
    }

    @Test
    void flywayIsEnabledInEveryDeployedProfile() {
        for (String profile : List.of("dev", "prod")) {
            Properties properties = flatten(MAIN_CONFIG.resolve("application-" + profile + ".yml"));
            assertThat(properties.getProperty("spring.flyway.enabled"))
                .as("profile %s must run migrations; without them ddl-auto=validate fails against an empty database", profile)
                .isEqualTo("true");
        }
    }

    @Test
    void flywayNeverAdoptsAnUnknownSchemaInProduction() {
        Properties properties = flatten(MAIN_CONFIG.resolve("application-prod.yml"));
        assertThat(properties.getProperty("spring.flyway.baseline-on-migrate"))
            .as("baseline-on-migrate would stamp an unknown production schema as version 1 instead of failing")
            .isEqualTo("false");
        assertThat(properties.getProperty("spring.flyway.validate-on-migrate"))
            .as("checksum validation is what catches an already-applied migration being edited after the fact")
            .isEqualTo("true");
    }

    private static List<Path> configFiles() {
        List<Path> files = new ArrayList<>();
        for (Path dir : List.of(MAIN_CONFIG, TEST_CONFIG)) {
            assertThat(dir).as("expected to run from the module directory").isDirectory();
            try (Stream<Path> found = Files.list(dir)) {
                found.filter(path -> path.getFileName().toString().endsWith(".yml")).forEach(files::add);
            } catch (IOException e) {
                throw new UncheckedIOException(e);
            }
        }
        return files;
    }

    /** Flattens a YAML file to dotted keys, the same way Spring Boot reads it. */
    private static Properties flatten(Path file) {
        YamlPropertiesFactoryBean factory = new YamlPropertiesFactoryBean();
        factory.setResources(new FileSystemResource(file));
        Properties properties = factory.getObject();
        return properties == null ? new Properties() : properties;
    }
}
