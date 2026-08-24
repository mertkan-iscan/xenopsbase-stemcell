package com.xenopsoftware.gateway.config;

import static org.assertj.core.api.Assertions.assertThat;

import com.xenopsoftware.gateway.GatewayApp;
import java.io.IOException;
import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Collectors;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.testcontainers.context.ImportTestcontainers;
import org.springframework.context.ApplicationContext;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.test.context.TestPropertySource;
import org.springframework.test.web.reactive.server.EntityExchangeResult;
import org.springframework.test.web.reactive.server.WebTestClient;

/**
 * The interactive login, end to end, against a real Keycloak (T-5.3).
 *
 * <h2>Why this exists</h2>
 *
 * Every other gateway integration test imports {@code TestSecurityConfiguration}, which mocks the
 * decoder and hands the test an already-authenticated principal. That is the right shape for
 * testing what happens <em>after</em> login, and it means the login itself — the redirect out, the
 * authorization request held in the session, the code exchange at the token endpoint, the claim
 * mapping on the way back — was covered by nothing.
 *
 * <p>That gap has a bill attached. #175, #176 and #180 were all defects in this flow, all found in
 * production by a person clicking a link, and #175 took three attempts and a wrong closure before
 * it was understood. This test walks the same path a browser walks, so the next one is found here.
 *
 * <p>{@code TestSecurityConfiguration} is deliberately <b>not</b> imported. Importing it would
 * replace the real {@code ReactiveJwtDecoder} and quietly make the whole test vacuous — the same
 * trap that made the core security slice pass while asserting nothing (T-5.2).
 *
 * <h2>How it drives the flow</h2>
 *
 * {@code WebTestClient} bound to the application context speaks to the gateway; a plain
 * {@link HttpClient} with redirects disabled speaks to Keycloak. Cookies are carried by hand in
 * both directions, because that is the part that actually matters here: the authorization request
 * lives in the gateway session between the redirect out and the callback back, and losing it is
 * precisely the #175 symptom.
 */
@SpringBootTest(
    classes = {
        GatewayApp.class,
        com.xenopsoftware.gateway.config.JacksonConfiguration.class,
        AsyncSyncConfiguration.class,
        RealClientRegistrationConfiguration.class,
    }
)
@EmbeddedSQL
@ImportTestcontainers({ ValkeyTestcontainer.class, KeycloakTestcontainer.class })
// AudienceValidator refuses to be built with an empty allow-list, and the shipped test config sets
// none because every other test mocks the decoder away. `account` is what Keycloak puts in `aud`
// for an ordinary user token; `gateway` is what the realm's audience mapper adds.
@TestPropertySource(
    properties = {
        "jhipster.security.oauth2.audience[0]=account",
        "jhipster.security.oauth2.audience[1]=gateway",
        // The test config shadows config/application.yml entirely, so neither the deployed base
        // path nor the exposure list is loaded: actuator sits at /actuator and exposes health
        // only. The authorization rules are written against /management/**, so without these two
        // the admin rule guards a path where no endpoint exists -- it still answers 401 and 403
        // correctly, and can never answer 200, which is exactly the assertion that matters here.
        "management.endpoints.web.base-path=/management",
        "management.endpoints.web.exposure.include=health,loggers",
    }
)
class OidcLoginFlowIT {

    /** Keycloak HTML-escapes the form action, so {@code &} arrives as {@code &amp;}. */
    private static final Pattern LOGIN_FORM_ACTION = Pattern.compile("action=\"([^\"]+)\"");

    @Autowired
    private ApplicationContext context;

    private WebTestClient gateway;
    private HttpClient keycloak;

    @BeforeEach
    void setUp() {
        // The base URL is not cosmetic. `application.yml` builds the callback from the
        // `{baseUrl}` template, and a client bound to the context with no base URL issues
        // relative requests -- so `{baseUrl}` expanded to nothing, the gateway sent Keycloak
        // `redirect_uri=/login/oauth2/code/oidc`, and Keycloak answered 400. Giving the client an
        // origin makes the template resolve exactly as it does behind the ingress.
        gateway = WebTestClient.bindToApplicationContext(context).configureClient().baseUrl("http://localhost").build();
        keycloak = HttpClient.newBuilder().followRedirects(HttpClient.Redirect.NEVER).connectTimeout(Duration.ofSeconds(10)).build();
    }

    @Test
    @DisplayName("a user who signs in at Keycloak comes back with an authenticated session")
    void theWholeAuthorizationCodeFlow() throws Exception {
        Login login = signIn(KeycloakTestcontainer.USER);

        // The session cookie is reissued on authentication. Asserting it changed is not
        // decoration: reusing the pre-login identifier is session fixation, and the flow would
        // otherwise look identical.
        assertThat(login.authenticatedSession()).isNotEqualTo(login.anonymousSession());

        // The control, and it is what gives the next assertion its meaning. Without a session this
        // endpoint answers 401 — so a 403 with the session is the gateway saying "I know who you
        // are, and it is not enough", rather than a denial that would have happened anyway.
        gateway.get().uri("/management/loggers").accept(MediaType.APPLICATION_JSON).exchange().expectStatus().isUnauthorized();

        gateway.get().uri("/management/loggers").cookie("SESSION", login.authenticatedSession()).exchange().expectStatus().isForbidden();
    }

    /**
     * Inverted from a characterization test when #186 was fixed (T-3.20).
     *
     * <p>It used to assert 403 here and say so loudly, because {@code oidcUserService()} read
     * authorities from the UserInfo response and Keycloak puts realm roles only in the access
     * token:
     *
     * <pre>
     * access token  realm_access.roles = ["app-admin","app-user"]
     * id token      no realm_access
     * userinfo      no realm_access
     * </pre>
     *
     * <p>Every principal was therefore built with an empty authority set, and every
     * {@code hasAuthority(ROLE_ADMIN)} rule on the session path denied everyone including the
     * administrator. Fail-closed, which is why nothing broke loudly enough to be noticed.
     *
     * <p>What this asserts now is the whole chain: the {@code roles} client scope being on the
     * token, {@code realm_access} being read as the nested object it is rather than the flat
     * {@code roles} claim Spring looks for by default, {@code app-admin} becoming
     * {@code ROLE_APP_ADMIN}, and the rule matching.
     */
    @Test
    @DisplayName("realm roles reach the session principal, so an admin reaches an admin endpoint")
    void realmRolesReachTheSessionPrincipal() throws Exception {
        Login admin = signIn(KeycloakTestcontainer.ADMIN_USER);

        gateway.get().uri("/management/loggers").cookie("SESSION", admin.authenticatedSession()).exchange().expectStatus().isOk();
    }

    @Test
    @DisplayName("and a user without the role still does not, so the rule is a rule")
    void aUserWithoutTheAdminRoleIsStillRefused() throws Exception {
        // The other half, and the one that makes the test above mean something. A change that
        // handed every principal ROLE_ADMIN would satisfy the admin case perfectly.
        Login user = signIn(KeycloakTestcontainer.USER);

        gateway.get().uri("/management/loggers").cookie("SESSION", user.authenticatedSession()).exchange().expectStatus().isForbidden();
    }

    @Test
    @DisplayName("preferred_username survives the change of claim source")
    void thePrincipalIsStillNamedByPreferredUsername() throws Exception {
        Login login = signIn(KeycloakTestcontainer.USER);

        // The authorities now come from the access token while the principal name and the id token
        // still come from the ID token, so this is exactly what a "just read the other token"
        // change breaks silently. /api/logout is the one endpoint that reads the OidcUser's id
        // token, so a principal built without one fails here and nowhere else.
        //
        // It is a POST, so it needs a real CSRF token rather than the csrf() mutator the other
        // logout tests use — which means this also exercises the cookie-to-header CSRF plumbing
        // against a real session, and nothing else did.
        EntityExchangeResult<byte[]> primed = gateway
            .get()
            .uri("/management/health")
            .cookie("SESSION", login.authenticatedSession())
            .exchange()
            .expectBody()
            .returnResult();
        String csrf = primed.getResponseCookies().getFirst("XSRF-TOKEN").getValue();

        gateway
            .post()
            .uri("/api/logout")
            .cookie("SESSION", login.authenticatedSession())
            .cookie("XSRF-TOKEN", csrf)
            .header("X-XSRF-TOKEN", csrf)
            .exchange()
            .expectStatus()
            .isOk()
            .expectBody()
            .jsonPath("$.logoutUrl")
            .exists();
    }

    @Test
    @DisplayName("the authorization request carries PKCE and a state, and is stored in the session")
    void theRedirectOutIsAProperAuthorizationRequest() {
        EntityExchangeResult<byte[]> redirect = gateway
            .get()
            .uri("/oauth2/authorization/oidc")
            .exchange()
            .expectStatus()
            .isFound()
            .expectBody()
            .returnResult();

        String location = redirect.getResponseHeaders().getFirst(HttpHeaders.LOCATION);
        assertThat(location)
            .isNotNull()
            .startsWith(KeycloakTestcontainer.issuerUri() + "/protocol/openid-connect/auth");

        Map<String, String> query = queryOf(URI.create(location));
        assertThat(query).containsEntry("response_type", "code").containsEntry("client_id", KeycloakTestcontainer.CLIENT_ID);
        assertThat(query.get("redirect_uri")).isEqualTo(KeycloakTestcontainer.CALLBACK_URI);
        assertThat(query.get("state")).isNotBlank();

        // PKCE is not configured anywhere in this repository — it is Spring Security's default for
        // a confidential client since 6.x. Asserting it means a future upgrade that changes the
        // default is caught here rather than by an auth server that starts rejecting the exchange.
        assertThat(query.get("code_challenge")).isNotBlank();
        assertThat(query).containsEntry("code_challenge_method", "S256");

        // The session is created by the redirect, because that is where the authorization request
        // is put. No session here means no possible callback (#175).
        assertThat(redirect.getResponseCookies().getFirst("SESSION")).isNotNull();
    }

    @Test
    @DisplayName("a callback with no session is refused once and retried, not answered with a 404")
    void aCallbackWithoutItsAuthorizationRequestIsHandled() throws Exception {
        // Obtain a genuine code, then present it on a connection that never held the authorization
        // request. This is what a stale tab, a lost session, or a second replica without shared
        // session state produces, and it is the exact shape of #175.
        Login login = signIn(KeycloakTestcontainer.USER, false);

        EntityExchangeResult<byte[]> orphaned = gateway
            .get()
            .uri(uri -> uri.path("/login/oauth2/code/oidc").queryParam("code", login.code()).queryParam("state", login.state()).build())
            .exchange()
            // Spring's default sends a failed login to /login?error, which does not exist in this
            // application and came back as a 404 naming a missing static resource — one hop from
            // the authentication error that actually caused it (T-3.17).
            .expectStatus()
            .isFound()
            .expectBody()
            .returnResult();

        assertThat(orphaned.getResponseHeaders().getFirst(HttpHeaders.LOCATION)).isEqualTo("/");

        // The retry guard. A second failure must not redirect again, or a browser loops until it
        // gives up with ERR_TOO_MANY_REDIRECTS.
        assertThat(orphaned.getResponseCookies().getFirst("oidc-retry")).isNotNull();
        String guard = orphaned.getResponseCookies().getFirst("oidc-retry").getValue();

        gateway
            .get()
            .uri(uri -> uri.path("/login/oauth2/code/oidc").queryParam("code", login.code()).queryParam("state", login.state()).build())
            .cookie("oidc-retry", guard)
            .exchange()
            .expectStatus()
            .isUnauthorized();
    }

    // ------------------------------------------------------------------------------------------
    // Driving the flow
    // ------------------------------------------------------------------------------------------

    private Login signIn(String username) throws Exception {
        return signIn(username, true);
    }

    /**
     * Walks the authorization-code flow and stops either at the code or after redeeming it.
     *
     * @param completeCallback false to obtain a real code without handing it back to the gateway,
     *                         which is how the orphaned-callback case gets a code that is valid in
     *                         every respect except the session it belongs to
     */
    private Login signIn(String username, boolean completeCallback) throws Exception {
        // 1. The gateway sends the browser to Keycloak and remembers the authorization request.
        EntityExchangeResult<byte[]> out = gateway
            .get()
            .uri("/oauth2/authorization/oidc")
            .exchange()
            .expectStatus()
            .isFound()
            .expectBody()
            .returnResult();

        String authorizeUrl = out.getResponseHeaders().getFirst(HttpHeaders.LOCATION);
        String anonymousSession = out.getResponseCookies().getFirst("SESSION").getValue();
        String stateSentOut = queryOf(URI.create(authorizeUrl)).get("state");

        // 2. Keycloak serves its login page and sets its own cookies.
        Cookies keycloakCookies = new Cookies();
        HttpResponse<String> loginPage = send(HttpRequest.newBuilder(URI.create(authorizeUrl)).GET(), keycloakCookies);
        assertThat(loginPage.statusCode()).as("Keycloak should serve a login form").isEqualTo(200);

        Matcher action = LOGIN_FORM_ACTION.matcher(loginPage.body());
        assertThat(action.find()).as("no form action in the Keycloak login page").isTrue();
        String formAction = action.group(1).replace("&amp;", "&");

        // 3. Credentials. Keycloak answers with the callback URL, code and state on the query.
        String form =
            "username=" +
            URLEncoder.encode(username, StandardCharsets.UTF_8) +
            "&password=" +
            URLEncoder.encode(KeycloakTestcontainer.PASSWORD, StandardCharsets.UTF_8) +
            "&credentialId=";
        HttpResponse<String> submitted = send(
            HttpRequest.newBuilder(URI.create(formAction))
                .header("Content-Type", "application/x-www-form-urlencoded")
                .POST(HttpRequest.BodyPublishers.ofString(form)),
            keycloakCookies
        );

        assertThat(submitted.statusCode())
            .as("Keycloak refused the credentials or re-rendered the form rather than redirecting")
            .isEqualTo(302);

        URI callback = URI.create(submitted.headers().firstValue("Location").orElseThrow());
        assertThat(callback.getPath()).isEqualTo("/login/oauth2/code/oidc");
        assertThat(queryOf(callback)).containsKey("code");
        // The state that comes back must be the state that went out. If this holds and the
        // callback still reports authorization_request_not_found, the fault is the session rather
        // than the round trip -- which is the fork #175 spent three attempts failing to isolate.
        assertThat(queryOf(callback).get("state")).isEqualTo(stateSentOut);
        Map<String, String> callbackParams = queryOf(callback);
        String code = callbackParams.get("code");
        String returnedState = callbackParams.get("state");

        if (!completeCallback) {
            return new Login(anonymousSession, null, code, returnedState);
        }

        // 4. The gateway redeems the code. This is the step that needs the session from (1).
        EntityExchangeResult<byte[]> back = gateway
            .get()
            .uri(uri -> uri.path("/login/oauth2/code/oidc").queryParam("code", code).queryParam("state", returnedState).build())
            .cookie("SESSION", anonymousSession)
            .exchange()
            .expectStatus()
            .isFound()
            .expectBody()
            .returnResult();

        assertThat(back.getResponseHeaders().getFirst(HttpHeaders.LOCATION))
            .as("a successful login should land on the application, not on an error page")
            .isEqualTo("/");

        assertThat(back.getResponseCookies().getFirst("SESSION"))
            .as("no session was issued, so the login did not actually authenticate anybody")
            .isNotNull();

        return new Login(anonymousSession, back.getResponseCookies().getFirst("SESSION").getValue(), code, returnedState);
    }

    private HttpResponse<String> send(HttpRequest.Builder request, Cookies cookies) throws IOException, InterruptedException {
        if (!cookies.isEmpty()) {
            request.header("Cookie", cookies.header());
        }
        HttpResponse<String> response = keycloak.send(request.build(), HttpResponse.BodyHandlers.ofString());
        cookies.absorb(response);
        return response;
    }

    private static Map<String, String> queryOf(URI uri) {
        String raw = uri.getRawQuery();
        if (raw == null || raw.isBlank()) {
            return Map.of();
        }
        return java.util.Arrays.stream(raw.split("&"))
            .map(pair -> pair.split("=", 2))
            .collect(
                Collectors.toMap(
                    pair -> java.net.URLDecoder.decode(pair[0], StandardCharsets.UTF_8),
                    pair -> pair.length > 1 ? java.net.URLDecoder.decode(pair[1], StandardCharsets.UTF_8) : "",
                    (first, second) -> first
                )
            );
    }

    /**
     * The session before authentication, the session after it, and the callback that produced it.
     *
     * @param authenticatedSession null when the caller asked to stop before redeeming the code
     */
    private record Login(String anonymousSession, String authenticatedSession, String code, String state) {}

    /** A cookie jar, because Keycloak's login form needs AUTH_SESSION_ID and KC_RESTART back. */
    private static final class Cookies {

        private final Map<String, String> jar = new LinkedHashMap<>();

        void absorb(HttpResponse<?> response) {
            for (String setCookie : response.headers().allValues("set-cookie")) {
                String first = setCookie.split(";", 2)[0];
                int equals = first.indexOf('=');
                if (equals > 0) {
                    jar.put(first.substring(0, equals), first.substring(equals + 1));
                }
            }
        }

        boolean isEmpty() {
            return jar.isEmpty();
        }

        String header() {
            return jar
                .entrySet()
                .stream()
                .map(e -> e.getKey() + "=" + e.getValue())
                .collect(Collectors.joining("; "));
        }
    }
}
