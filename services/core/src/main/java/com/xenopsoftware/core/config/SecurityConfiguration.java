package com.xenopsoftware.core.config;

import static org.springframework.security.config.Customizer.withDefaults;
import static org.springframework.security.oauth2.core.oidc.StandardClaimNames.PREFERRED_USERNAME;

import com.xenopsoftware.core.security.*;
import com.xenopsoftware.core.security.oauth2.AudienceValidator;
import java.util.*;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.convert.converter.Converter;
import org.springframework.security.authentication.AbstractAuthenticationToken;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import com.xenopsoftware.core.web.rest.errors.SecurityProblemSupport;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.oauth2.core.DelegatingOAuth2TokenValidator;
import org.springframework.security.oauth2.core.OAuth2TokenValidator;
import org.springframework.security.oauth2.jwt.*;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationConverter;
import org.springframework.security.web.SecurityFilterChain;
import tech.jhipster.config.JHipsterProperties;

@Configuration
@EnableMethodSecurity(securedEnabled = true)
public class SecurityConfiguration {

    private final JHipsterProperties jHipsterProperties;

    private final SecurityProblemSupport problemSupport;

    @Value("${spring.security.oauth2.client.provider.oidc.issuer-uri}")
    private String issuerUri;

    public SecurityConfiguration(JHipsterProperties jHipsterProperties, SecurityProblemSupport problemSupport) {
        this.jHipsterProperties = jHipsterProperties;
        this.problemSupport = problemSupport;
    }

    @Bean
    public SecurityFilterChain filterChain(HttpSecurity http) {
        http.csrf(csrf -> csrf.disable())
            .authorizeHttpRequests(authz ->
                // prettier-ignore
                authz
                    .requestMatchers("/api/authenticate").permitAll()
                    .requestMatchers("/api/auth-info").permitAll()
                    .requestMatchers("/api/admin/**").hasAuthority(AuthoritiesConstants.ADMIN)
                    .requestMatchers("/api/**").authenticated()
                    .requestMatchers("/v3/api-docs/**").hasAuthority(AuthoritiesConstants.ADMIN)
                    .requestMatchers("/management/health").permitAll()
                    .requestMatchers("/management/health/**").permitAll()
                    .requestMatchers("/management/info").permitAll()
                    .requestMatchers("/management/prometheus").permitAll()
                    .requestMatchers("/management/**").hasAuthority(AuthoritiesConstants.ADMIN)
                    // Terminal rule, for the reason spelled out in the gateway's copy of this
                    // configuration: an unmatched request is denied, not permitted. Every path
                    // this service currently serves is named above, so nothing changes today --
                    // it is here so that the first path added outside those prefixes does not
                    // come back as an unexplained 403.
                    .anyRequest().authenticated()
            )
            .sessionManagement(session -> session.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
            // Resource server ONLY. The core service validates the token the
            // gateway relays inward; it never starts a login and never calls
            // another service on a user's behalf.
            //
            // .oauth2Client(withDefaults()) was generated here and is removed
            // deliberately. It requires a ClientRegistrationRepository, so the
            // service refuses to start without OAuth2 CLIENT credentials it has
            // no use for -- and the message names a missing bean rather than
            // the unnecessary feature that demanded it.
            //
            // If the core ever needs to call another service as itself, add a
            // client-credentials registration on purpose, and put this back.
            // 401 and 403 as RFC 9457 problem documents (T-3.8). Security runs as a filter,
            // before any controller exists, so ExceptionTranslator -- a @RestControllerAdvice --
            // never sees these. Without this, every error carries a problem document except the
            // two most common ones, which return an empty body.
            //
            // Set on the resource server too: it installs its own BearerToken handlers, which
            // would otherwise win for any request carrying an Authorization header.
            .exceptionHandling(e -> e.authenticationEntryPoint(problemSupport).accessDeniedHandler(problemSupport))
            .oauth2ResourceServer(oauth2 ->
                oauth2
                    .authenticationEntryPoint(problemSupport)
                    .accessDeniedHandler(problemSupport)
                    .jwt(jwt -> jwt.jwtAuthenticationConverter(authenticationConverter()))
            );
        return http.build();
    }

    Converter<Jwt, AbstractAuthenticationToken> authenticationConverter() {
        JwtAuthenticationConverter jwtAuthenticationConverter = new JwtAuthenticationConverter();
        jwtAuthenticationConverter.setJwtGrantedAuthoritiesConverter(
            new Converter<Jwt, Collection<GrantedAuthority>>() {
                @Override
                public Collection<GrantedAuthority> convert(Jwt jwt) {
                    return SecurityUtils.extractAuthorityFromClaims(jwt.getClaims());
                }
            }
        );
        jwtAuthenticationConverter.setPrincipalClaimName(PREFERRED_USERNAME);
        return jwtAuthenticationConverter;
    }

    @Bean
    JwtDecoder jwtDecoder() {
        NimbusJwtDecoder jwtDecoder = JwtDecoders.fromOidcIssuerLocation(issuerUri);

        OAuth2TokenValidator<Jwt> audienceValidator = new AudienceValidator(jHipsterProperties.getSecurity().getOauth2().getAudience());
        OAuth2TokenValidator<Jwt> withIssuer = JwtValidators.createDefaultWithIssuer(issuerUri);
        OAuth2TokenValidator<Jwt> withAudience = new DelegatingOAuth2TokenValidator<>(withIssuer, audienceValidator);

        jwtDecoder.setJwtValidator(withAudience);

        return jwtDecoder;
    }
}
