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
import java.util.LinkedHashSet;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
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
import org.springframework.security.oauth2.client.web.server.ServerOAuth2AuthorizedClientRepository;
import org.springframework.security.oauth2.client.web.server.WebSessionServerOAuth2AuthorizedClientRepository;
import org.springframework.security.oauth2.core.DelegatingOAuth2TokenValidator;
import org.springframework.security.oauth2.core.OAuth2AuthenticationException;
import org.springframework.security.oauth2.core.OAuth2Error;
import org.springframework.security.oauth2.core.OAuth2TokenValidator;
import org.springframework.security.oauth2.core.endpoint.OAuth2AuthorizationRequest;
import org.springframework.security.oauth2.core.oidc.user.DefaultOidcUser;
import org.springframework.security.oauth2.core.oidc.user.OidcUser;
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

    /**
     * WHERE THE ACCESS AND REFRESH TOKENS LIVE (T-3.19, #179).
     *
     * <p>Spring Boot's default is {@code AuthenticatedPrincipalServerOAuth2AuthorizedClientRepository}
     * over an {@code InMemoryReactiveOAuth2AuthorizedClientService} -- a {@code ConcurrentHashMap}
     * in one JVM's heap. T-2.11 moved the SESSION to Valkey and raised the deployment to two
     * replicas on the strength of it, but the authorized client is a SEPARATE store that the
     * session's location says nothing about. It stayed in the heap.
     *
     * <p>So the session was shared and the tokens were not, and the replicas were not
     * interchangeable after all. The pod that completed the login held the only copy of the
     * tokens; the other pod read the same session out of Valkey, found the user authenticated,
     * found no authorized client, and threw {@code ClientAuthorizationRequiredException} --
     * which {@code OAuth2AuthorizationRequestRedirectWebFilter} answers with a 302 into the
     * Keycloak authorization endpoint, for EVERY request, whatever it asked for.
     *
     * <p>Measured on the deployed gateway with one real session cookie replayed against both
     * pods directly, bypassing the ingress:
     *
     * <pre>
     *   request                      pod A (logged in here)   pod B
     *   GET /            text/html   200                      302 -> Keycloak
     *   GET /app.css     text/css    200                      302 -> Keycloak
     *   GET /services/core/api/documents  json  200            302 -> Keycloak
     * </pre>
     *
     * <p>With no cookie at all both pods answered identically and correctly, which is why this
     * hid behind T-3.18: the asset-request fix is real and works, and the redirects it was
     * blamed for a second time were coming from somewhere else entirely. From the browser it
     * looked exactly like the old bug -- a stylesheet and a fetch both loading the Keycloak
     * authorization URL, tripping {@code style-src} and {@code connect-src} -- because roughly
     * half of every page's requests were load-balanced onto the pod without the tokens.
     *
     * <p>{@code WebSessionServerOAuth2AuthorizedClientRepository} keeps the authorized client in
     * the WebSession, which is already in Valkey and already replicated. The tokens then share
     * the session's lifetime and its invalidation, which is the correct coupling: a session that
     * has been ended must not leave a usable refresh token behind.
     */
    @Bean
    public ServerOAuth2AuthorizedClientRepository authorizedClientRepository() {
        return new WebSessionServerOAuth2AuthorizedClientRepository();
    }

    @Bean
    public SecurityWebFilterChain springSecurityFilterChain(
        ServerHttpSecurity http,
        ServerAuthenticationEntryPoint authenticationEntryPoint
    ) {
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
            .exceptionHandling(e -> e.authenticationEntryPoint(authenticationEntryPoint))
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
    @Bean
    public ServerAuthenticationEntryPoint authenticationEntryPoint() {
        MediaTypeServerWebExchangeMatcher wantsHtml = new MediaTypeServerWebExchangeMatcher(MediaType.TEXT_HTML);

        // IGNORING */* IS WHAT MAKES THIS MATCHER MEAN WHAT IT SAYS (T-3.18, #175).
        //
        // MediaTypeServerWebExchangeMatcher matches */* by default, and a browser sends */* on
        // every subresource: `Accept: text/css,*/*;q=0.1` for a stylesheet, `*/*` for a script.
        // So every asset request counted as "browser navigation" and was answered with a 302 into
        // /oauth2/authorization/oidc instead of a 401.
        //
        // The consequence was not a cosmetic wrong status. Each of those redirects MINTED A NEW
        // AUTHORIZATION REQUEST -- a new state, nonce and PKCE verifier -- so loading one page
        // created several, each replacing the last. The callback for the navigation the user
        // actually made then arrived with a state that had been superseded, and failed with
        // authorization_request_not_found. Reported from a browser as intermittent login, several
        // `oidc` state entries at once, and finally ERR_TOO_MANY_REDIRECTS, with the console
        // complaining that the Keycloak authorization URL had been loaded as a stylesheet.
        //
        // Measured before and after on the deployed gateway:
        //
        //   Accept                       before   after
        //   text/html,...,*/*;q=0.8      302      302   browser navigation, unchanged
        //   text/css,*/*;q=0.1           302      401
        //   */*                          302      401
        //   application/json             401      401
        //
        // Only an explicit text/html now redirects, which is what the comment above always claimed.
        wantsHtml.setIgnoredMediaTypes(Set.of(MediaType.ALL));

        DelegatingServerAuthenticationEntryPoint.DelegateEntry browserNavigation = new DelegatingServerAuthenticationEntryPoint.DelegateEntry(
            wantsHtml,
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
     * Builds the session principal's authorities from {@code realm_access.roles} in the
     * <b>access token</b>.
     *
     * <h3>Why the access token and not UserInfo, which is what this used to read (T-3.20, #186)</h3>
     *
     * Keycloak puts realm roles in the access token and nowhere else. Measured against the
     * deployed realm, for a user holding {@code app-admin} and {@code app-user}:
     *
     * <pre>
     * access token   realm_access.roles = ["app-admin","app-user"]
     * id token       no realm_access
     * userinfo       no realm_access
     * </pre>
     *
     * <p>This method read UserInfo, so {@code extractAuthorityFromClaims} was handed a map that
     * had never contained a role, returned nothing, and every principal was built with an empty
     * authority set. Every {@code hasAuthority(ROLE_ADMIN)} rule on the browser-session path —
     * {@code /api/admin/**}, {@code /management/**}, {@code /v3/api-docs/**} — therefore denied
     * everyone, the administrator included, and {@code health.show-details: when_authorized} could
     * authorize nobody. Fail-closed, which is why it never announced itself.
     *
     * <p>Reading the access token also makes this service and core agree <em>by construction</em>.
     * Core maps authorities from the access token it is handed; adding a Keycloak mapper to copy
     * the roles into the ID token would have worked too, and would have left the two services
     * reading two different claim sources that are only equal until someone changes one of them.
     *
     * <h3>What is validated, and what deliberately is not</h3>
     *
     * Signature, issuer and expiry, through the provider's own JWKS. <b>Not</b> audience: this
     * token's {@code aud} names the services the gateway will call downstream with it, not the
     * gateway itself, so {@link AudienceValidator} — which is correct for the resource-server path
     * — would reject a token that is perfectly valid here.
     *
     * <p>A token that cannot be decoded fails the login rather than producing a principal with no
     * roles. The silent-empty-set outcome is the bug this replaces; it must not be reachable by a
     * second route.
     *
     * @return a {@link ReactiveOAuth2UserService} whose principal carries the realm's roles
     */
    @Bean
    public ReactiveOAuth2UserService<OidcUserRequest, OidcUser> oidcUserService() {
        final OidcReactiveOAuth2UserService delegate = new OidcReactiveOAuth2UserService();
        // One decoder per registration, built on first use. NimbusReactiveJwtDecoder caches the
        // JWKS itself, so rebuilding it per login would refetch the key set on every sign-in.
        final Map<String, ReactiveJwtDecoder> accessTokenDecoders = new ConcurrentHashMap<>();

        return userRequest ->
            delegate
                .loadUser(userRequest)
                .flatMap(user -> {
                    ClientRegistration registration = userRequest.getClientRegistration();
                    ReactiveJwtDecoder decoder = accessTokenDecoders.computeIfAbsent(
                        registration.getRegistrationId(),
                        ignored -> accessTokenDecoder(registration)
                    );

                    return decoder
                        .decode(userRequest.getAccessToken().getTokenValue())
                        .map(accessToken ->
                            new DefaultOidcUser(
                                new LinkedHashSet<>(SecurityUtils.extractAuthorityFromClaims(accessToken.getClaims())),
                                user.getIdToken(),
                                user.getUserInfo(),
                                PREFERRED_USERNAME
                            )
                        )
                        .onErrorMap(JwtException.class, e ->
                            // Named, because the alternative is an authentication failure whose
                            // cause reads as a generic OAuth error and sends the next person to
                            // look at the login flow rather than at the token.
                            new OAuth2AuthenticationException(
                                new OAuth2Error(
                                    "invalid_access_token",
                                    "the access token could not be decoded, so the user's roles are unknown",
                                    null
                                ),
                                e
                            )
                        );
                });
    }

    /**
     * A decoder for the access token the gateway was just issued. Signature, issuer and expiry
     * only — see {@link #oidcUserService()} for why audience validation would be wrong here.
     */
    private ReactiveJwtDecoder accessTokenDecoder(ClientRegistration registration) {
        NimbusReactiveJwtDecoder decoder = new NimbusReactiveJwtDecoder(registration.getProviderDetails().getJwkSetUri());
        decoder.setJwtValidator(JwtValidators.createDefaultWithIssuer(registration.getProviderDetails().getIssuerUri()));
        return decoder;
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
