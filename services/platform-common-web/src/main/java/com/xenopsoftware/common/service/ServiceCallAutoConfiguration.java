package com.xenopsoftware.common.service;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.AutoConfiguration;
import org.springframework.boot.autoconfigure.condition.ConditionalOnBean;
import org.springframework.boot.autoconfigure.condition.ConditionalOnMissingBean;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.security.oauth2.jwt.JwtDecoder;

/**
 * The service-to-service seam, wired but inert (T-9.4).
 *
 * <h2>Present in every service, active in none of them yet</h2>
 *
 * This template has one service, which calls nothing, so {@link ServiceTokens#configured()} is
 * false and {@link ServiceCalls#to} would throw if anything used it. That is deliberate and is the
 * same posture as the other seams: the mechanism exists so that the first fork to need it adds
 * configuration rather than architecture.
 *
 * <p>What it costs to be present: three beans and a filter that returns immediately when the
 * request carries no service header. What it would cost to be absent: the first inter-service call
 * in a fork gets invented at a call site, with a shared secret or a trusted header, because those
 * are what somebody reaches for when there is nothing there.
 *
 * <h2>The token URI defaults to the resource server's own issuer</h2>
 *
 * A service already knows which realm it trusts — it validates every incoming token against it. A
 * separately configured token endpoint could point somewhere else, and a service that accepts
 * tokens from one realm while obtaining them from another is a misconfiguration nothing would
 * report. Overridable for the case where the two genuinely differ.
 */
@AutoConfiguration
@EnableConfigurationProperties(ServiceEndpoints.class)
public class ServiceCallAutoConfiguration {

    @Bean
    @ConditionalOnMissingBean
    public ServiceTokens serviceTokens(
        @Value(
            "${platform.service-auth.token-uri:${spring.security.oauth2.resourceserver.jwt.issuer-uri:}/protocol/openid-connect/token}"
        ) String tokenUri,
        @Value("${platform.service-auth.client-id:}") String clientId,
        @Value("${platform.service-auth.client-secret:}") String clientSecret
    ) {
        return new ServiceTokens(tokenUri, clientId, clientSecret);
    }

    @Bean
    @ConditionalOnMissingBean
    public ServiceCalls serviceCalls(ServiceTokens tokens, ServiceEndpoints endpoints) {
        return new ServiceCalls(tokens, endpoints);
    }

    /**
     * Conditional on a {@link JwtDecoder}, because verifying an inbound service credential means
     * verifying a Keycloak signature and a service with no resource-server configuration has
     * nothing to verify it against.
     *
     * <p>{@code @ConditionalOnBean} is safe here for the reason it is safe elsewhere in these
     * modules and would not be on a component-scanned class: auto-configuration is evaluated after
     * the beans it asks about exist.
     */
    @Bean
    @ConditionalOnMissingBean
    @ConditionalOnBean(JwtDecoder.class)
    public ServiceAuthenticationFilter serviceAuthenticationFilter(JwtDecoder decoder) {
        return new ServiceAuthenticationFilter(decoder);
    }
}
