package com.xenopsoftware.gateway.config;

import static org.springframework.security.config.Customizer.withDefaults;
import static org.springframework.security.oauth2.core.oidc.StandardClaimNames.PREFERRED_USERNAME;
import static org.springframework.security.web.server.util.matcher.ServerWebExchangeMatchers.pathMatchers;

import com.github.benmanes.caffeine.cache.Cache;
import com.github.benmanes.caffeine.cache.Caffeine;
import com.xenopsoftware.gateway.security.AuthoritiesConstants;
import com.xenopsoftware.gateway.security.SecurityUtils;
import com.xenopsoftware.gateway.security.oauth2.AudienceValidator;
import com.xenopsoftware.gateway.web.filter.OidcAuthenticationFailureHandler;
import com.xenopsoftware.gateway.web.filter.ProblemDetailAuthenticationEntryPoint;
import java.time.Duration;
import java.util.Arrays;
import java.util.HashSet;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.function.Consumer;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.ParameterizedTypeReference;
import org.springframework.core.convert.converter.Converter;
import org.springframework.security.authentication.AbstractAuthenticationToken;
import org.springframework.security.config.annotation.method.configuration.EnableReactiveMethodSecurity;
import org.springframework.security.config.web.server.SecurityWebFiltersOrder;
import org.springframework.security.config.web.server.ServerHttpSecurity;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.oauth2.client.oidc.userinfo.OidcReactiveOAuth2UserService;
import org.springframework.security.oauth2.client.oidc.userinfo.OidcUserRequest;
import org.springframework.security.oauth2.client.registration.ClientRegistration;
import org.springframework.security.oauth2.client.registration.ReactiveClientRegistrationRepository;
import org.springframework.security.oauth2.client.userinfo.ReactiveOAuth2UserService;
import org.springframework.security.oauth2.client.web.server.DefaultServerOAuth2AuthorizationRequestResolver;
import org.springframework.security.oauth2.client.web.server.ServerOAuth2AuthorizationRequestResolver;
import org.springframework.security.oauth2.core.DelegatingOAuth2TokenValidator;
import org.springframework.security.oauth2.core.OAuth2TokenValidator;
import org.springframework.security.oauth2.core.endpoint.OAuth2AuthorizationRequest;
import org.springframework.security.oauth2.core.oidc.user.DefaultOidcUser;
import org.springframework.security.oauth2.core.oidc.user.OidcUser;
import org.springframework.security.oauth2.core.oidc.user.OidcUserAuthority;
import org.springframework.security.oauth2.jwt.*;
import org.springframework.security.oauth2.server.resource.authentication.ReactiveJwtAuthenticationConverter;
import org.springframework.http.MediaType;
import org.springframework.security.web.server.SecurityWebFilterChain;
import org.springframework.security.web.server.ServerAuthenticationEntryPoint;
import org.springframework.security.web.server.DelegatingServerAuthenticationEntryPoint;
import org.springframework.security.web.server.authentication.RedirectServerAuthenticationEntryPoint;
import org.springframework.security.web.server.util.matcher.MediaTypeServerWebExchangeMatcher;
import org.springframework.security.web.server.csrf.CookieServerCsrfTokenRepository;
import org.springframework.security.web.server.csrf.ServerCsrfTokenRequestAttributeHandler;
import org.springframework.security.web.server.header.ReferrerPolicyServerHttpHeadersWriter;
import org.springframework.security.web.server.header.XFrameOptionsServerHttpHeadersWriter.Mode;
import org.springframework.security.web.server.util.matcher.NegatedServerWebExchangeMatcher;
import org.springframework.security.web.server.util.matcher.OrServerWebExchangeMatcher;
import org.springframework.web.reactive.function.client.WebClient;
import reactor.core.publisher.Flux;
import reactor.core.publisher.Mono;
import tech.jhipster.config.JHipsterProperties;
import tech.jhipster.web.filter.reactive.CookieCsrfFilter;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

@Configuration
@EnableReactiveMethodSecurity
public class SecurityConfiguration {

    private static final Logger LOG = LoggerFactory.getLogger(SecurityConfiguration.class);

    private final JHipsterProperties jHipsterProperties;

    @Value("${spring.security.oauth2.client.provider.oidc.issuer-uri}")
    private String issuerUri;

    private final ReactiveClientRegistrationRepository clientRegistrationRepository;

    // See https://github.com/jhipster/generator-jhipster/issues/18868
    // We don't use a distributed cache or the user selected cache implementation here on purpose
    private final Cache<String, Mono<Jwt>> users = Caffeine.newBuilder()
        .maximumSize(10_000)
        .expireAfterWrite(Duration.ofHours(1))
        .recordStats()
        .build();

    public SecurityConfiguration(ReactiveClientRegistrationRepository clientRegistrationRepository, JHipsterProperties jHipsterProperties) {
        this.clientRegistrationRepository = clientRegistrationRepository;
        this.jHipsterProperties = jHipsterProperties;
    }

    @Bean
    public SecurityWebFilterChain springSecurityFilterChain(ServerHttpSecurity http) {
        http.securityMatcher(
            new NegatedServerWebExchangeMatcher(
                new OrServerWebExchangeMatcher(pathMatchers("/app/**", "/i18n/**", "/content/**", "/swagger-ui/**"))
            )
        )
            .cors(withDefaults())
            .csrf(csrf ->
                csrf
                    .csrfTokenRepository(CookieServerCsrfTokenRepository.withHttpOnlyFalse())
                    // See https://stackoverflow.com/q/74447118/65681
                    .csrfTokenRequestHandler(new ServerCsrfTokenRequestAttributeHandler())
            )
            // See https://github.com/spring-projects/spring-security/issues/5766
            .addFilterAt(new CookieCsrfFilter(), SecurityWebFiltersOrder.REACTOR_CONTEXT)
            .headers(headers ->
                headers
                    .contentSecurityPolicy(csp -> csp.policyDirectives(jHipsterProperties.getSecurity().getContentSecurityPolicy()))
                    .frameOptions(frameOptions -> frameOptions.mode(Mode.DENY))
                    .referrerPolicy(referrer ->
                        referrer.policy(ReferrerPolicyServerHttpHeadersWriter.ReferrerPolicy.STRICT_ORIGIN_WHEN_CROSS_ORIGIN)
                    )
                    .permissionsPolicy(permissions ->
                        permissions.policy(
                            "camera=(), fullscreen=(self), geolocation=(), gyroscope=(), magnetometer=(), microphone=(), midi=(), payment=(), sync-xhr=()"
                        )
                    )
            )
            .authorizeExchange(authz ->
                // prettier-ignore
                authz
                    .pathMatchers("/api/authenticate").permitAll()
                    .pathMatchers("/api/auth-info").permitAll()
                    // Reached only by an internal forward from the CircuitBreaker filter, after
                    // the original request has already been authorised. Requiring auth again here
                    // would turn "downstream is down" into "you are not logged in" (T-3.9).
                    .pathMatchers("/fallback/**").permitAll()
                    .pathMatchers("/api/admin/**").hasAuthority(AuthoritiesConstants.ADMIN)
                    .pathMatchers("/api/**").authenticated()
                    .pathMatchers("/services/*/management/health/readiness").permitAll()
                    .pathMatchers("/services/*/v3/api-docs").hasAuthority(AuthoritiesConstants.ADMIN)
                    .pathMatchers("/services/**").authenticated()
                    .pathMatchers("/v3/api-docs/**").hasAuthority(AuthoritiesConstants.ADMIN)
                    .pathMatchers("/management/health").permitAll()
                    .pathMatchers("/management/health/**").permitAll()
                    .pathMatchers("/management/info").permitAll()
                    .pathMatchers("/management/prometheus").permitAll()
                    .pathMatchers("/management/**").hasAuthority(AuthoritiesConstants.ADMIN)
                    // The terminal rule, and NOT redundant.
                    //
                    // An exchange matching none of the rules above is DENIED, not permitted:
                    // DelegatingReactiveAuthorizationManager ends its chain with
                    // defaultIfEmpty(new AuthorizationDecision(false)). Everything outside
                    // /api, /services, /management and /v3/api-docs fell into that gap --
                    // including "/", which is where oauth2Login sends the browser after a
                    // successful login.
                    //
                    // The two halves of that looked nothing alike. Anonymous, the denial
                    // reaches authenticationEntryPoint and comes back as a redirect to
                    // Keycloak, so an unauthenticated visit behaved perfectly. Authenticated,
                    // the same denial is a real AccessDeniedException and comes back as a bare
                    // 403 with an empty body. So logging in was what broke the page, and only
                    // for people who had done it.
                    .anyExchange().authenticated()
            )
            // An unauthenticated API request must fail visibly (T-3.8). Without this,
            // oauth2Login's redirecting entry point sends a 302 to the Keycloak login page, the
            // client follows it, and receives 200 OK with a body of HTML -- an exchange that
            // contains no error status and no error body, so a client checking the status code
            // concludes it worked.
            //
            // Browser navigation still redirects: it is matched by Accept: text/html rather than
            // by path, because the frontend and the API share the /api prefix and it is the
            // CALLER's expectation that decides which answer is useful.
            .exceptionHandling(e -> e.authenticationEntryPoint(authenticationEntryPoint()))
            // The failure handler is explicit because the default is wrong for this application
            // (T-3.17). Spring sends a failed login to /login?error, and there is no /login here
            // -- no controller, no route, no static file -- so a stale authorization request came
            // back as a 404 naming a missing static resource, one hop from the authentication
            // error that actually caused it.
            .oauth2Login(oauth2 ->
                oauth2
                    .authorizationRequestResolver(authorizationRequestResolver(this.clientRegistrationRepository))
                    .authenticationFailureHandler(new OidcAuthenticationFailureHandler())
            )
            .oauth2Client(withDefaults())
            .oauth2ResourceServer(oauth2 -> oauth2.jwt(jwt -> jwt.jwtAuthenticationConverter(jwtAuthenticationConverter())));
        return http.build();
    }

    /**
     * 401 with a problem detail for API clients, redirect to login for browser navigation.
     *
     * <p>The discriminator is {@code Accept: text/html}, which a browser navigating to a page
     * sends and an API client does not. Matching on the path instead would be wrong in both
     * directions here: the SPA is served from the same origin as the API, and a user typing an
     * {@code /api} URL into the address bar is a browser that deserves a login page.
     */
    private ServerAuthenticationEntryPoint authenticationEntryPoint() {
        DelegatingServerAuthenticationEntryPoint.DelegateEntry browserNavigation = new DelegatingServerAuthenticationEntryPoint.DelegateEntry(
            new MediaTypeServerWebExchangeMatcher(MediaType.TEXT_HTML),
            new RedirectServerAuthenticationEntryPoint("/oauth2/authorization/oidc")
        );

        DelegatingServerAuthenticationEntryPoint entryPoint = new DelegatingServerAuthenticationEntryPoint(browserNavigation);
        // Anything that did not ask for HTML -- fetch, curl, a service account -- gets the 401.
        entryPoint.setDefaultEntryPoint(new ProblemDetailAuthenticationEntryPoint());
        return entryPoint;
    }

    private ServerOAuth2AuthorizationRequestResolver authorizationRequestResolver(
        ReactiveClientRegistrationRepository clientRegistrationRepository
    ) {
        DefaultServerOAuth2AuthorizationRequestResolver authorizationRequestResolver = new DefaultServerOAuth2AuthorizationRequestResolver(
            clientRegistrationRepository
        );
        if (this.issuerUri.contains("auth0.com")) {
            authorizationRequestResolver.setAuthorizationRequestCustomizer(authorizationRequestCustomizer());
        }
        return authorizationRequestResolver;
    }

    private Consumer<OAuth2AuthorizationRequest.Builder> authorizationRequestCustomizer() {
        return customizer ->
            customizer.authorizationRequestUri(uriBuilder ->
                uriBuilder.queryParam("audience", jHipsterProperties.getSecurity().getOauth2().getAudience()).build()
            );
    }

    Converter<Jwt, Mono<AbstractAuthenticationToken>> jwtAuthenticationConverter() {
        ReactiveJwtAuthenticationConverter jwtAuthenticationConverter = new ReactiveJwtAuthenticationConverter();
        jwtAuthenticationConverter.setJwtGrantedAuthoritiesConverter(
            new Converter<Jwt, Flux<GrantedAuthority>>() {
                @Override
                public Flux<GrantedAuthority> convert(Jwt jwt) {
                    return Flux.fromIterable(SecurityUtils.extractAuthorityFromClaims(jwt.getClaims()));
                }
            }
        );
        // preferred_username where present, `sub` otherwise.
        //
        // preferred_username only exists when the token carries the `profile`
        // scope. Service-account tokens never have it, and a user token from a
        // client without that scope does not either. The generated code used it
        // unconditionally, so any such token produced
        //   NullPointerException: Cannot invoke "Object.hashCode()" because "key" is null
        // -- a 500 from the single entry point, saying nothing about claims.
        //
        // `sub` is mandatory in an OIDC token and is the stable identifier
        // anyway, so it is the correct fallback rather than a defensive hack.
        jwtAuthenticationConverter.setPrincipalClaimName(PREFERRED_USERNAME);

        return jwtAuthenticationConverter;
    }

    /**
     * Map authorities from "groups" or "roles" claim in ID Token.
     *
     * @return a {@link ReactiveOAuth2UserService} that has the groups from the IdP.
     */
    @Bean
    public ReactiveOAuth2UserService<OidcUserRequest, OidcUser> oidcUserService() {
        final OidcReactiveOAuth2UserService delegate = new OidcReactiveOAuth2UserService();

        return userRequest -> {
            // Delegate to the default implementation for loading a user
            return delegate.loadUser(userRequest).map(user -> {
                Set<GrantedAuthority> mappedAuthorities = new HashSet<>();

                user.getAuthorities().forEach(authority -> {
                    if (authority instanceof OidcUserAuthority oidcUserAuthority) {
                        mappedAuthorities.addAll(SecurityUtils.extractAuthorityFromClaims(oidcUserAuthority.getUserInfo().getClaims()));
                    }
                });

                return new DefaultOidcUser(mappedAuthorities, user.getIdToken(), user.getUserInfo(), PREFERRED_USERNAME);
            });
        };
    }

    @Bean
    ReactiveJwtDecoder jwtDecoder(ReactiveClientRegistrationRepository registrations) {
        Mono<ClientRegistration> clientRegistration = registrations.findByRegistrationId("oidc");

        return clientRegistration
            .map(oidc ->
                createJwtDecoder(
                    oidc.getProviderDetails().getIssuerUri(),
                    oidc.getProviderDetails().getJwkSetUri(),
                    oidc.getProviderDetails().getUserInfoEndpoint().getUri()
                )
            )
            .block();
    }

    private ReactiveJwtDecoder createJwtDecoder(String issuerUri, String jwkSetUri, String userInfoUri) {
        NimbusReactiveJwtDecoder jwtDecoder = new NimbusReactiveJwtDecoder(jwkSetUri);
        OAuth2TokenValidator<Jwt> audienceValidator = new AudienceValidator(jHipsterProperties.getSecurity().getOauth2().getAudience());
        OAuth2TokenValidator<Jwt> withIssuer = JwtValidators.createDefaultWithIssuer(issuerUri);
        OAuth2TokenValidator<Jwt> withAudience = new DelegatingOAuth2TokenValidator<>(withIssuer, audienceValidator);

        jwtDecoder.setJwtValidator(withAudience);

        return new ReactiveJwtDecoder() {
            @Override
            public Mono<Jwt> decode(String token) throws JwtException {
                return jwtDecoder.decode(token).flatMap(jwt -> enrich(token, jwt));
            }

            private Mono<Jwt> enrich(String token, Jwt jwt) {
                // Only look up user information if identity claims are missing
                if (jwt.hasClaim("given_name") && jwt.hasClaim("family_name")) {
                    return Mono.just(jwt);
                }
                // No subject means no user to look up, and a null cache key
                // throws before the request is even made. Service-account
                // tokens legitimately reach here.
                if (jwt.getSubject() == null) {
                    return Mono.just(jwt);
                }
                // Get user info from `users` cache if present
                return Optional.ofNullable(users.getIfPresent(jwt.getSubject())).orElseGet(() ->
                    WebClient.create()
                        .get()
                        .uri(userInfoUri)
                        .headers(headers -> headers.setBearerAuth(token))
                        .retrieve()
                        .bodyToMono(new ParameterizedTypeReference<Map<String, Object>>() {})
                        .map(userInfo ->
                            Jwt.withTokenValue(jwt.getTokenValue())
                                .subject(jwt.getSubject())
                                .audience(jwt.getAudience())
                                .headers(headers -> headers.putAll(jwt.getHeaders()))
                                .claims(claims -> {
                                    // Every field here is optional in practice.
                                    // The generated code called .toString() on
                                    // the result of get(), so a provider that
                                    // omits any of them produced a 500 rather
                                    // than a token with fewer claims.
                                    Object rawUsername = userInfo.get("preferred_username");
                                    Object rawSub = userInfo.get("sub");
                                    String username = rawUsername == null ? null : rawUsername.toString();
                                    String subject = rawSub == null ? null : rawSub.toString();
                                    // special handling for Auth0
                                    if (username != null && subject != null && subject.contains("|") && username.contains("@")) {
                                        userInfo.put("email", username);
                                    }
                                    // Allow full name in a name claim - happens with Auth0
                                    if (userInfo.get("name") != null) {
                                        String[] name = userInfo.get("name").toString().split("\\s+");
                                        if (name.length > 0) {
                                            userInfo.put("given_name", name[0]);
                                            userInfo.put("family_name", String.join(" ", Arrays.copyOfRange(name, 1, name.length)));
                                        }
                                    }
                                    claims.putAll(userInfo);
                                })
                                .claims(claims -> claims.putAll(jwt.getClaims()))
                                .build()
                        )
                        // Retrieve user info from OAuth provider if not already loaded
                        // Put user info into the `users` cache
                        .doOnNext(newJwt -> users.put(jwt.getSubject(), Mono.just(newJwt)))
                        // Enrichment is an ENHANCEMENT, never a precondition.
                        // Keycloak returns 403 from /userinfo for a
                        // service-account token because there is no user
                        // behind it -- which turned a valid token into a 500
                        // from the gateway. The token has already been
                        // cryptographically validated at this point; failing to
                        // decorate it with a display name is not an
                        // authentication failure.
                        .onErrorResume(e -> {
                            LOG.debug("userinfo enrichment failed for sub={}, continuing with the raw token", jwt.getSubject(), e);
                            return Mono.just(jwt);
                        })
                );
            }
        };
    }
}
