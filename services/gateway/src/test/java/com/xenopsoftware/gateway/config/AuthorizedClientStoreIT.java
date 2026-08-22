package com.xenopsoftware.gateway.config;

import static org.assertj.core.api.Assertions.assertThat;

import com.xenopsoftware.gateway.IntegrationTest;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.security.oauth2.client.web.server.ServerOAuth2AuthorizedClientRepository;
import org.springframework.security.oauth2.client.web.server.WebSessionServerOAuth2AuthorizedClientRepository;

/**
 * WHERE THE TOKENS ARE KEPT, ASSERTED RATHER THAN ASSUMED (T-3.19, #179).
 *
 * <p>T-2.11 moved the session to Valkey and raised the deployment to two replicas on the strength
 * of it. The access and refresh tokens did not move, because Spring Boot keeps them in a store the
 * session's location says nothing about -- {@code InMemoryReactiveOAuth2AuthorizedClientService},
 * a map in one JVM's heap. The session replicated and the tokens did not.
 *
 * <p>What that looked like is the reason this test is a bean assertion and not a nicety. The pod
 * that had not handled the login read the same session out of Valkey, found the user
 * authenticated, found no authorized client, and threw {@code ClientAuthorizationRequiredException}
 * -- which Spring answers with a 302 into the Keycloak authorization endpoint for every request,
 * whatever it asked for. Half of every page's requests were load-balanced onto that pod, so a
 * stylesheet and an XHR both tried to load the authorization URL and were refused by
 * {@code style-src} and {@code connect-src}. It presented as a CSP problem and as a
 * recurrence of T-3.18, and it was neither.
 *
 * <p>Nothing failed at startup, nothing was logged, and every unit and integration test passed,
 * because with one replica the store's location is invisible. It only becomes wrong at a replica
 * count set somewhere else entirely -- so the guard has to live here, next to the choice.
 */
@IntegrationTest
class AuthorizedClientStoreIT {

    @Autowired
    private ServerOAuth2AuthorizedClientRepository authorizedClientRepository;

    @Test
    @DisplayName("authorized clients are held in the WebSession, which is shared, not in the heap, which is not")
    void authorizedClientsAreSessionBacked() {
        // Boot's default is AuthenticatedPrincipalServerOAuth2AuthorizedClientRepository over an
        // in-memory service. Deleting the bean in SecurityConfiguration brings it silently back.
        assertThat(authorizedClientRepository).isInstanceOf(WebSessionServerOAuth2AuthorizedClientRepository.class);
    }
}
