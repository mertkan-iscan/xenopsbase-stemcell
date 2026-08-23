package com.xenopsoftware.gateway.config;

import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.security.oauth2.client.registration.ClientRegistration;
import org.springframework.security.oauth2.client.registration.ClientRegistrations;
import org.springframework.security.oauth2.client.registration.InMemoryReactiveClientRegistrationRepository;
import org.springframework.security.oauth2.client.registration.ReactiveClientRegistrationRepository;
import org.springframework.security.oauth2.core.AuthorizationGrantType;

/**
 * The {@code oidc} client registration, pointed at the real Keycloak container (T-5.3).
 *
 * <h2>Why this is a bean rather than three properties</h2>
 *
 * The obvious approach is to let Boot build the repository from
 * {@code spring.security.oauth2.client.registration.oidc.*} supplied through
 * {@code @DynamicPropertySource}. It does not work, and the way it fails is worth writing down
 * because it looks like a typo for as long as you believe it should have worked.
 *
 * <p>Boot gates that auto-configuration on {@code ClientsConfiguredCondition}, which binds
 * {@code spring.security.oauth2.client.registration} as a <b>Map</b> — so it has to enumerate
 * property names, not merely look one up. The property source that {@code @ImportTestcontainers}
 * contributes does not enumerate, so the condition reports <i>"registered clients is not
 * available"</i> and no repository is created, while the resource-server side of the very same
 * mechanism works fine because {@code @ConditionalOnProperty} only ever does a direct lookup. One
 * half of the OAuth configuration arrives and the other silently does not.
 *
 * <h2>Discovery is real too</h2>
 *
 * {@link ClientRegistrations#fromIssuerLocation} fetches the container's own discovery document,
 * so the authorization, token, JWK and end-session endpoints are Keycloak's rather than values
 * this file asserts. That matters: a hand-written registration would keep passing after an upgrade
 * moved an endpoint, which is precisely the class of breakage a real-dependency test exists to
 * catch.
 *
 * <p>Everything else mirrors {@code application.yml}: the same scopes, the same grant type, and
 * the same {@code {baseUrl}} redirect template, so the callback the gateway builds here is
 * constructed the way the deployed one is.
 */
@TestConfiguration(proxyBeanMethods = false)
public class RealClientRegistrationConfiguration {

    @Bean
    ReactiveClientRegistrationRepository clientRegistrationRepository() {
        ClientRegistration oidc = ClientRegistrations
            .fromIssuerLocation(KeycloakTestcontainer.issuerUri())
            .registrationId("oidc")
            .clientId(KeycloakTestcontainer.CLIENT_ID)
            .clientSecret(KeycloakTestcontainer.TEST_GATEWAY_CLIENT_SECRET)
            .authorizationGrantType(AuthorizationGrantType.AUTHORIZATION_CODE)
            .redirectUri("{baseUrl}/login/oauth2/code/{registrationId}")
            // As deployed. `offline_access` is deliberately absent — see the long note in
            // application.yml about why asking for it would be a downgrade rather than a feature.
            .scope("openid", "profile", "email")
            .build();

        return new InMemoryReactiveClientRegistrationRepository(oidc);
    }
}
