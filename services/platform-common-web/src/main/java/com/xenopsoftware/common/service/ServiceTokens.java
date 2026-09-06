package com.xenopsoftware.common.service;

import java.time.Duration;
import java.time.Instant;
import java.util.Map;
import java.util.concurrent.atomic.AtomicReference;
import org.springframework.http.MediaType;
import org.springframework.util.LinkedMultiValueMap;
import org.springframework.util.MultiValueMap;
import org.springframework.web.client.RestClient;

/**
 * This service's own credential (T-9.4): a {@code client_credentials} token from the realm, cached
 * until shortly before it expires.
 *
 * <p>Per service and rotatable on its own. A shared secret would make rotating any of them an
 * outage for all of them, and would make "which service called" unanswerable — the callee reads
 * the caller's identity out of this token, so a shared one would let any service claim to be any
 * other.
 *
 * <p>Cached because a token fetch per outbound call would put Keycloak on the hot path of every
 * inter-service request. Refreshed a minute early, so a request never carries a token that expires
 * in flight.
 *
 * <h2>The failure this is shaped to make visible</h2>
 *
 * The realm's copy of the secret and the Kubernetes Secret must agree. When they do not, Keycloak's
 * token endpoint answers {@code invalid_client} and this class throws — which is the loudest signal
 * available, because there is no request downstream to see failing. The caller never obtained a
 * token, so no inter-service call is ever attempted, and every pod stays Ready. See
 * docs/runbooks/authorization.md.
 */
public class ServiceTokens {

    private record CachedToken(String token, Instant refreshAfter) {}

    private final RestClient tokenEndpoint;
    private final String clientId;
    private final String clientSecret;
    private final AtomicReference<CachedToken> cached = new AtomicReference<>();

    public ServiceTokens(String tokenUri, String clientId, String clientSecret) {
        // RestClient.builder() rather than an injected RestClient.Builder: a shared library must
        // not depend on whether the service that includes it happens to have that
        // auto-configuration present.
        this.tokenEndpoint = RestClient.builder().baseUrl(tokenUri).build();
        this.clientId = clientId == null ? "" : clientId;
        this.clientSecret = clientSecret == null ? "" : clientSecret;
    }

    /**
     * Whether this service has credentials of its own.
     *
     * <p>A service that calls nothing needs none, and the template ships with none configured —
     * so this is false by default and the seam is inert rather than broken.
     */
    public boolean configured() {
        return !clientId.isBlank() && !clientSecret.isBlank();
    }

    /** A valid token for this service, fetched only when the cached one is close to expiring. */
    public String current() {
        if (!configured()) {
            throw new IllegalStateException(
                "This service has no credentials of its own, so it cannot call another service. " +
                    "Set platform.service-auth.client-id and platform.service-auth.client-secret, and " +
                    "add a matching svc-<name> client to the realm (T-9.4)."
            );
        }
        CachedToken token = cached.get();
        if (token != null && Instant.now().isBefore(token.refreshAfter())) {
            return token.token();
        }

        MultiValueMap<String, String> form = new LinkedMultiValueMap<>();
        form.add("grant_type", "client_credentials");
        form.add("client_id", clientId);
        form.add("client_secret", clientSecret);

        Map<?, ?> response = tokenEndpoint.post().contentType(MediaType.APPLICATION_FORM_URLENCODED).body(form).retrieve().body(Map.class);

        String issued = String.valueOf(response.get("access_token"));
        long expiresIn = response.get("expires_in") instanceof Number seconds ? seconds.longValue() : 300;

        // Refreshed a minute early, and never less than thirty seconds out: a realm configured
        // with a very short token lifetime would otherwise make every call re-fetch, turning the
        // cache into a token endpoint stampede.
        cached.set(new CachedToken(issued, Instant.now().plus(Duration.ofSeconds(Math.max(30, expiresIn - 60)))));
        return issued;
    }
}
