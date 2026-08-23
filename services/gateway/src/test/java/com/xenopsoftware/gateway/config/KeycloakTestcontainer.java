package com.xenopsoftware.gateway.config;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
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
 * A real Keycloak for the gateway, preloaded with the realm that production uses (T-5.3).
 *
 * <h2>Why the gateway needs its own, when core already has one</h2>
 *
 * The two services meet Keycloak from opposite ends and the container has to be configured
 * differently for each. Core is a <em>resource server</em>: it receives a token and validates it,
 * so its harness only needs an issuer. The gateway is the <em>OIDC client</em>: it runs the
 * authorization-code flow, holds the session, stores the authorization request between the
 * redirect out and the callback back, and exchanges the code at the token endpoint using a client
 * secret.
 *
 * <p>None of that was covered by any test in this repository, and it is where every login defect
 * of the last week lived — #175 (the authorization request missing from the session on callback),
 * #176 (a stylesheet request treated as browser navigation), #180 (tokens stored somewhere other
 * than the session). Each was found in production, by a person, on the third or fourth attempt.
 *
 * <h2>Duplicated rather than shared, on purpose</h2>
 *
 * This overlaps {@code com.xenopsoftware.core.config.KeycloakTestcontainer}. Sharing it would mean
 * core publishing a test-jar and the gateway depending on it, which makes one service's build a
 * prerequisite for the other's — the coupling ADR-0001 keeps the two poms separate to avoid, paid
 * for in every CI run and every clone. The shared thing that actually matters, the realm, is
 * shared: both read the same deployed file.
 *
 * <h2>The realm is the deployed file, with one documented mutation</h2>
 *
 * The JSON handed to Keycloak is read out of {@code platform/envs/dev/keycloak/realm-import.yaml},
 * the same file Argo CD applies. The deployed {@code gateway} client trusts exactly one callback:
 *
 * <pre>redirectUris: [https://app-dev.xenopsoftware.com/login/oauth2/code/oidc]</pre>
 *
 * A gateway under test is not that, so Keycloak would answer with {@code Invalid parameter:
 * redirect_uri} — correctly. The localhost callback is therefore <strong>appended</strong>, never
 * substituted, exactly as {@code infra/scripts/dev-realm.sh} does for local development. Appending
 * means this file cannot become a way to loosen the deployed realm: it only ever adds to a copy
 * that lives inside a container for the length of a test run.
 */
public interface KeycloakTestcontainer {
    String REALM = "xenopsbase";

    /** Only needed because the committed realm carries a SOPS placeholder rather than a secret. */
    String TEST_GATEWAY_CLIENT_SECRET = "test-only-gateway-secret";

    /** The confidential client the gateway authenticates as, straight from the deployed realm. */
    String CLIENT_ID = "gateway";

    /**
     * Where the gateway's callback lives when the test drives it through {@code WebTestClient}
     * bound to the application context: host {@code localhost}, no port, because that binding
     * never opens a socket. Registered with Keycloak so the authorization request is accepted.
     */
    String CALLBACK_URI = "http://localhost/login/oauth2/code/oidc";

    /** A user with {@code app-user} only, from the deployed realm. */
    String USER = "smoke";
    /** A user with {@code app-user} and {@code app-admin}, from the deployed realm. */
    String ADMIN_USER = "smoke-admin";
    /** The password both carry in the deployed realm. Not a secret: the realm is public. */
    String PASSWORD = "smoke-dev-only";

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
        // The client half. The shipped config points the provider at `DO_NOT_CALL` so that nothing
        // resolves it by accident, and leaves client-secret with no default at all, so both have
        // to be supplied here or the context does not start.
        registry.add("spring.security.oauth2.client.provider.oidc.issuer-uri", KeycloakTestcontainer::issuerUri);
        registry.add("spring.security.oauth2.client.registration.oidc.client-id", () -> CLIENT_ID);
        registry.add("spring.security.oauth2.client.registration.oidc.client-secret", () -> TEST_GATEWAY_CLIENT_SECRET);

        // The resource-server half. The gateway is both: it accepts a bearer token on /services/**
        // as well as holding a browser session.
        registry.add("spring.security.oauth2.resourceserver.jwt.issuer-uri", KeycloakTestcontainer::issuerUri);
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

                allowLocalhostCallback(realm);

                // Jackson 3, chosen rather than imported by habit. Both major versions are on this
                // classpath, and picking the wrong one compiles cleanly and fails at runtime.
                String json = new tools.jackson.databind.ObjectMapper().writeValueAsString(realm);
                return json.replace("${GATEWAY_CLIENT_SECRET}", TEST_GATEWAY_CLIENT_SECRET);
            } catch (IOException e) {
                throw new UncheckedIOException("could not read the realm from " + yaml, e);
            }
        }

        /**
         * Appends the test callback to the {@code gateway} client. Mirrors what
         * {@code infra/scripts/dev-realm.sh} does for local development, for the same reason and
         * with the same restraint: append, never replace, so the deployed callback survives and
         * this cannot be used to widen the real realm.
         */
        @SuppressWarnings("unchecked")
        private static void allowLocalhostCallback(Map<String, Object> realm) {
            List<Map<String, Object>> clients = (List<Map<String, Object>>) realm.get("clients");
            if (clients == null) {
                throw new IllegalStateException("the realm declares no clients; it is not the file this expects");
            }

            Map<String, Object> gateway = clients
                .stream()
                .filter(client -> CLIENT_ID.equals(client.get("clientId")))
                .findFirst()
                .orElseThrow(() ->
                    // Loud rather than a redirect_uri error twenty seconds later inside Keycloak.
                    new IllegalStateException("the realm has no '" + CLIENT_ID + "' client, so there is nothing to log in as")
                );

            appendTo(gateway, "redirectUris", CALLBACK_URI);
            appendTo(gateway, "webOrigins", "http://localhost");
        }

        @SuppressWarnings("unchecked")
        private static void appendTo(Map<String, Object> client, String key, String value) {
            List<String> existing = (List<String>) client.get(key);
            List<String> widened = existing == null ? new ArrayList<>() : new ArrayList<>(existing);
            widened.add(value);
            client.put(key, widened);
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
                throw new IllegalStateException(
                    "could not locate the repository root: no ancestor of " +
                    Path.of("").toAbsolutePath() +
                    " contains a platform/ directory"
                );
            }
            return candidate;
        }
    }
}
