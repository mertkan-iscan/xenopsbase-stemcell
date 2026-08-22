package com.xenopsoftware.core.config;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.Map;
import org.slf4j.LoggerFactory;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.containers.output.Slf4jLogConsumer;
import org.testcontainers.containers.wait.strategy.Wait;
import org.testcontainers.images.builder.Transferable;
import org.testcontainers.junit.jupiter.Container;
import org.yaml.snakeyaml.Yaml;

/**
 * A real Keycloak, preloaded with the realm that production uses (T-4.2).
 *
 * <h2>Why a container rather than a mock</h2>
 *
 * {@code TestSecurityConfiguration} mocks {@link org.springframework.security.oauth2.jwt.JwtDecoder},
 * so before this every integration test authenticated against nothing. Signature validation, issuer
 * validation, audience enforcement, the {@code roles} client scope and the mapping from realm roles
 * to Spring authorities were exercised by no test in either service — and every authorization
 * defect this project has hit lived in exactly that gap:
 *
 * <ul>
 *   <li>tokens carrying no {@code aud} claim at all, because Keycloak adds none by itself
 *   <li>{@code realm_access} missing because declaring {@code defaultClientScopes} replaced the
 *       realm defaults instead of extending them, dropping {@code roles}
 *   <li>{@code offline_access} refused at the token endpoint for a user without the role
 * </ul>
 *
 * <p>Each is invisible to a mocked decoder and obvious to a real one.
 *
 * <h2>The realm is the production file, not a copy of it</h2>
 *
 * The JSON handed to Keycloak is read out of
 * {@code platform/envs/dev/keycloak/realm-import.yaml} at test time — the same file Argo CD applies
 * to the cluster. A copy would drift, and it would drift silently: the tests would keep passing
 * against a realm nobody deploys, which is the failure this whole harness exists to prevent.
 *
 * <p>The only substitution is {@code ${GATEWAY_CLIENT_SECRET}}, which is a SOPS placeholder in the
 * committed file and has no value outside the cluster.
 *
 * <h2>Startup is shared</h2>
 *
 * {@code withReuse(true)} and a static field, matching {@link DatabaseTestcontainer}: one Keycloak
 * for the suite rather than one per class. Keycloak is the slowest container here, so this is the
 * difference between a harness people use and one they switch off.
 */
public interface KeycloakTestcontainer {
    String REALM = "xenopsbase";

    /** Only needed because the committed realm carries a SOPS placeholder rather than a secret. */
    String TEST_GATEWAY_CLIENT_SECRET = "test-only-gateway-secret";

    /**
     * The client the realm already provides for automated callers: public, direct access grants
     * enabled, and an audience mapper that puts {@code gateway} in {@code aud} — which is what
     * {@code AudienceValidator} requires. Tests do not need a client of their own.
     */
    String TEST_CLIENT_ID = "smoke-tests";

    @Container
    GenericContainer<?> keycloakContainer = new GenericContainer<>("quay.io/keycloak/keycloak:26.7.1")
        .withExposedPorts(8080)
        .withEnv("KC_BOOTSTRAP_ADMIN_USERNAME", "admin")
        .withEnv("KC_BOOTSTRAP_ADMIN_PASSWORD", "admin")
        .withCopyToContainer(Transferable.of(RealmJson.read()), "/opt/keycloak/data/import/realm.json")
        .withCommand("start-dev", "--import-realm")
        // The discovery document, not the port and not the health endpoint. Keycloak accepts
        // connections well before the realm import finishes, so a port check hands tests a server
        // that 404s on the realm they are about to use.
        .waitingFor(
            Wait
                .forHttp("/realms/" + REALM + "/.well-known/openid-configuration")
                .forPort(8080)
                .forStatusCode(200)
                .withStartupTimeout(Duration.ofMinutes(3))
        )
        .withLogConsumer(new Slf4jLogConsumer(LoggerFactory.getLogger(KeycloakTestcontainer.class)))
        .withReuse(true);

    /** The issuer as the JVM running the tests sees it. */
    static String issuerUri() {
        return "http://" + keycloakContainer.getHost() + ":" + keycloakContainer.getMappedPort(8080) + "/realms/" + REALM;
    }

    @DynamicPropertySource
    static void registerProperties(DynamicPropertyRegistry registry) {
        // Both, deliberately. The resource-server property is what builds the real JwtDecoder; the
        // client-provider one exists because the shipped config points it at a hostname that must
        // never be reached from a test (`DO_NOT_CALL`), and leaving it there makes any code path
        // that resolves it hang rather than fail.
        registry.add("spring.security.oauth2.resourceserver.jwt.issuer-uri", KeycloakTestcontainer::issuerUri);
        registry.add("spring.security.oauth2.client.provider.oidc.issuer-uri", KeycloakTestcontainer::issuerUri);
    }

    /** Reads {@code spec.realm} out of the deployed KeycloakRealmImport and renders it as JSON. */
    final class RealmJson {

        private RealmJson() {}

        static String read() {
            Path yaml = repositoryRoot().resolve("platform/envs/dev/keycloak/realm-import.yaml");
            try {
                Map<String, Object> document = new Yaml().load(Files.readString(yaml));
                @SuppressWarnings("unchecked")
                Map<String, Object> spec = (Map<String, Object>) document.get("spec");
                @SuppressWarnings("unchecked")
                Map<String, Object> realm = (Map<String, Object>) spec.get("realm");

                // Jackson 3, chosen rather than imported by habit. Both major versions are on this
                // classpath -- 2.x through the AWS SDK and the OpenAPI tooling, 3.x because Boot 4
                // registers its converters with it -- and picking the wrong one compiles cleanly
                // and fails at runtime, which cost a day on T-3.16.
                String json = new tools.jackson.databind.ObjectMapper().writeValueAsString(realm);
                return json.replace("${GATEWAY_CLIENT_SECRET}", TEST_GATEWAY_CLIENT_SECRET);
            } catch (IOException e) {
                throw new UncheckedIOException("could not read the realm from " + yaml, e);
            }
        }

        /**
         * Walks up from the working directory until {@code platform/} appears, rather than assuming
         * how deep the module sits. Maven runs tests from the module directory and IDEs do not
         * always agree with it, and a hard-coded {@code ../..} fails as a confusing
         * file-not-found rather than as a wrong assumption.
         */
        private static Path repositoryRoot() {
            Path candidate = Path.of("").toAbsolutePath();
            while (candidate != null && !Files.isDirectory(candidate.resolve("platform"))) {
                candidate = candidate.getParent();
            }
            if (candidate == null) {
                throw new IllegalStateException("could not locate the repository root: no ancestor of " +
                    Path.of("").toAbsolutePath() + " contains a platform/ directory");
            }
            return candidate;
        }
    }
}
