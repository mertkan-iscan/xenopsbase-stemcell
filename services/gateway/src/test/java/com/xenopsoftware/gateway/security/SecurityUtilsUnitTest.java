package com.xenopsoftware.gateway.security;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.*;
import org.junit.jupiter.api.Test;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.ReactiveSecurityContextHolder;
import org.springframework.security.core.userdetails.User;
import org.springframework.security.core.userdetails.UserDetails;
import org.springframework.security.oauth2.core.oidc.OidcIdToken;
import org.springframework.security.oauth2.core.oidc.user.DefaultOidcUser;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationToken;
import reactor.util.context.Context;

/**
 * Test class for the {@link SecurityUtils} utility class.
 */
class SecurityUtilsUnitTest {

    @Test
    void testGetCurrentUserLogin() {
        String login = SecurityUtils.getCurrentUserLogin()
            .contextWrite(ReactiveSecurityContextHolder.withAuthentication(new UsernamePasswordAuthenticationToken("admin", "admin")))
            .block();
        assertThat(login).isEqualTo("admin");
    }

    @Test
    void testIsAuthenticated() {
        Boolean isAuthenticated = SecurityUtils.isAuthenticated()
            .contextWrite(ReactiveSecurityContextHolder.withAuthentication(new UsernamePasswordAuthenticationToken("admin", "admin")))
            .block();
        assertThat(isAuthenticated).isTrue();
    }

    @Test
    void testAnonymousIsNotAuthenticated() {
        Collection<GrantedAuthority> authorities = new ArrayList<>();
        authorities.add(new SimpleGrantedAuthority(AuthoritiesConstants.ANONYMOUS));
        Boolean isAuthenticated = SecurityUtils.isAuthenticated()
            .contextWrite(
                ReactiveSecurityContextHolder.withAuthentication(new UsernamePasswordAuthenticationToken("admin", "admin", authorities))
            )
            .block();
        assertThat(isAuthenticated).isFalse();
    }

    @Test
    void testHasCurrentUserAnyOfAuthorities() {
        Collection<GrantedAuthority> authorities = new ArrayList<>();
        authorities.add(new SimpleGrantedAuthority(AuthoritiesConstants.USER));
        Context context = ReactiveSecurityContextHolder.withAuthentication(
            new UsernamePasswordAuthenticationToken("admin", "admin", authorities)
        );
        Boolean hasCurrentUserThisAuthority = SecurityUtils.hasCurrentUserAnyOfAuthorities(
            AuthoritiesConstants.USER,
            AuthoritiesConstants.ADMIN
        )
            .contextWrite(context)
            .block();
        assertThat(hasCurrentUserThisAuthority).isTrue();

        hasCurrentUserThisAuthority = SecurityUtils.hasCurrentUserAnyOfAuthorities(
            AuthoritiesConstants.ANONYMOUS,
            AuthoritiesConstants.ADMIN
        )
            .contextWrite(context)
            .block();
        assertThat(hasCurrentUserThisAuthority).isFalse();
    }

    @Test
    void testHasCurrentUserNoneOfAuthorities() {
        Collection<GrantedAuthority> authorities = new ArrayList<>();
        authorities.add(new SimpleGrantedAuthority(AuthoritiesConstants.USER));
        Context context = ReactiveSecurityContextHolder.withAuthentication(
            new UsernamePasswordAuthenticationToken("admin", "admin", authorities)
        );
        Boolean hasCurrentUserThisAuthority = SecurityUtils.hasCurrentUserNoneOfAuthorities(
            AuthoritiesConstants.USER,
            AuthoritiesConstants.ADMIN
        )
            .contextWrite(context)
            .block();
        assertThat(hasCurrentUserThisAuthority).isFalse();

        hasCurrentUserThisAuthority = SecurityUtils.hasCurrentUserNoneOfAuthorities(
            AuthoritiesConstants.ANONYMOUS,
            AuthoritiesConstants.ADMIN
        )
            .contextWrite(context)
            .block();
        assertThat(hasCurrentUserThisAuthority).isTrue();
    }

    @Test
    void testHasCurrentUserThisAuthority() {
        Collection<GrantedAuthority> authorities = new ArrayList<>();
        authorities.add(new SimpleGrantedAuthority(AuthoritiesConstants.USER));
        Context context = ReactiveSecurityContextHolder.withAuthentication(
            new UsernamePasswordAuthenticationToken("admin", "admin", authorities)
        );
        Boolean hasCurrentUserThisAuthority = SecurityUtils.hasCurrentUserThisAuthority(AuthoritiesConstants.USER)
            .contextWrite(context)
            .block();
        assertThat(hasCurrentUserThisAuthority).isTrue();

        hasCurrentUserThisAuthority = SecurityUtils.hasCurrentUserThisAuthority(AuthoritiesConstants.ADMIN).contextWrite(context).block();
        assertThat(hasCurrentUserThisAuthority).isFalse();
    }

    /**
     * The four principal shapes below all reach {@code getCurrentUserLogin} in production, and each
     * carries the login in a different place. The method walks them in order and returns the first
     * that matches, so a reordering of those branches changes which name is logged and attributed
     * without failing to compile — these tests pin the shape-to-login mapping rather than the order.
     */
    @Test
    void readsTheLoginFromAUserDetailsPrincipal() {
        UserDetails user = User.withUsername("jdoe").password("ignored").authorities(AuthoritiesConstants.USER).build();
        String login = SecurityUtils.getCurrentUserLogin()
            .contextWrite(
                ReactiveSecurityContextHolder.withAuthentication(
                    new UsernamePasswordAuthenticationToken(user, user.getPassword(), user.getAuthorities())
                )
            )
            .block();
        assertThat(login).isEqualTo("jdoe");
    }

    /** The bearer-token path: the login lives in the {@code preferred_username} claim, not in the subject. */
    @Test
    void readsTheLoginFromThePreferredUsernameClaimOfAJwt() {
        Jwt jwt = Jwt.withTokenValue("token")
            .header("alg", "none")
            .subject("8f14e45f-ceea-467a-9575-1a1b2c3d4e5f")
            .claim("preferred_username", "jdoe")
            .build();
        String login = SecurityUtils.getCurrentUserLogin()
            .contextWrite(ReactiveSecurityContextHolder.withAuthentication(new JwtAuthenticationToken(jwt)))
            .block();
        assertThat(login).isEqualTo("jdoe");
    }

    /** The browser login path, where the principal is the OIDC user assembled from the id token. */
    @Test
    void readsTheLoginFromThePreferredUsernameAttributeOfAnOidcUser() {
        OidcIdToken idToken = OidcIdToken.withTokenValue("id-token")
            .subject("8f14e45f-ceea-467a-9575-1a1b2c3d4e5f")
            .claim("preferred_username", "jdoe")
            .build();
        DefaultOidcUser oidcUser = new DefaultOidcUser(List.of(new SimpleGrantedAuthority(AuthoritiesConstants.USER)), idToken);
        String login = SecurityUtils.getCurrentUserLogin()
            .contextWrite(
                ReactiveSecurityContextHolder.withAuthentication(
                    new UsernamePasswordAuthenticationToken(oidcUser, "ignored", oidcUser.getAuthorities())
                )
            )
            .block();
        assertThat(login).isEqualTo("jdoe");
    }

    /**
     * An OIDC user without the claim, and a principal of a shape nobody anticipated, both yield no
     * login rather than a subject id or a {@code toString()}. Worth pinning because the fallback is
     * what ends up in an audit trail: a stringified object there reads like a username and would be
     * attributed to a person.
     */
    @Test
    void yieldsNoLoginWhenNoPrincipalShapeCarriesOne() {
        OidcIdToken withoutUsername = OidcIdToken.withTokenValue("id-token").subject("8f14e45f-ceea-467a-9575-1a1b2c3d4e5f").build();
        DefaultOidcUser oidcUser = new DefaultOidcUser(List.of(new SimpleGrantedAuthority(AuthoritiesConstants.USER)), withoutUsername);
        String login = SecurityUtils.getCurrentUserLogin()
            .contextWrite(
                ReactiveSecurityContextHolder.withAuthentication(
                    new UsernamePasswordAuthenticationToken(oidcUser, "ignored", oidcUser.getAuthorities())
                )
            )
            .block();
        assertThat(login).isNull();

        String fromUnknownShape = SecurityUtils.getCurrentUserLogin()
            .contextWrite(
                ReactiveSecurityContextHolder.withAuthentication(new UsernamePasswordAuthenticationToken(new Object(), "ignored"))
            )
            .block();
        assertThat(fromUnknownShape).isNull();
    }

    /** No security context at all is the unauthenticated case, and it must be empty rather than an error. */
    @Test
    void yieldsNoLoginWhenThereIsNoSecurityContext() {
        assertThat(SecurityUtils.getCurrentUserLogin().block()).isNull();
    }
}
