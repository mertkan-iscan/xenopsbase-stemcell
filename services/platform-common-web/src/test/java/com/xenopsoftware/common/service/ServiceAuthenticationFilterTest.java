package com.xenopsoftware.common.service;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import jakarta.servlet.FilterChain;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.security.oauth2.jwt.JwtException;

/**
 * What the service credential is allowed to prove, and what it is not (T-9.4).
 *
 * <p>Every case here is a way the seam fails <em>open</em> if it is wrong: a header that is
 * trusted without verification, a valid user token accepted as a service, or an identity left on a
 * pooled thread. None of those produce an error on their own.
 */
class ServiceAuthenticationFilterTest {

    private final JwtDecoder decoder = mock(JwtDecoder.class);
    private final ServiceAuthenticationFilter filter = new ServiceAuthenticationFilter(decoder);

    @AfterEach
    void clear() {
        SecurityContextHolder.clearContext();
    }

    private static Jwt jwtWithRealmRoles(String azp, List<String> roles) {
        return Jwt.withTokenValue("token")
            .header("alg", "RS256")
            .claim("azp", azp)
            .claim("realm_access", Map.of("roles", roles))
            .issuedAt(Instant.now())
            .expiresAt(Instant.now().plusSeconds(300))
            .build();
    }

    @Test
    @DisplayName("no service header is an ordinary edge request, not a refusal")
    void absenceIsNotRefusal() throws Exception {
        MockHttpServletRequest request = new MockHttpServletRequest("GET", "/api/platform/probe");
        MockHttpServletResponse response = new MockHttpServletResponse();
        FilterChain chain = mock(FilterChain.class);

        filter.doFilter(request, response, chain);

        assertThat(response.getStatus()).as("a request with no service credential is not a service call").isEqualTo(200);
        assertThat(filter.refusedCount()).isZero();
        assertThat(SecurityContextHolder.getContext().getAuthentication()).isNull();
    }

    @Test
    @DisplayName("a service token holding svc-caller becomes an authority @PreAuthorize can name")
    void aServiceTokenBecomesAnAuthority() throws Exception {
        when(decoder.decode(anyString())).thenReturn(jwtWithRealmRoles("svc-core", List.of("svc-caller")));

        MockHttpServletRequest request = new MockHttpServletRequest("GET", "/api/platform/probe");
        request.addHeader(ServiceAuthenticationFilter.HEADER, "Bearer whatever");
        MockHttpServletResponse response = new MockHttpServletResponse();

        // The assertion has to happen INSIDE the chain: the filter clears the context in a finally
        // block, so reading it afterwards would see null and pass for the wrong reason.
        FilterChain chain = (req, res) ->
            assertThat(SecurityContextHolder.getContext().getAuthentication().getAuthorities())
                .extracting(Object::toString)
                .containsExactly(ServiceAuthenticationFilter.SERVICE_ROLE);

        filter.doFilter(request, response, chain);

        assertThat(response.getStatus()).isEqualTo(200);
        assertThat(filter.refusedCount()).isZero();
    }

    @Test
    @DisplayName("a VALID token without svc-caller is refused, not downgraded to an ordinary request")
    void aUserTokenCannotClaimToBeAService() throws Exception {
        when(decoder.decode(anyString())).thenReturn(jwtWithRealmRoles("gateway", List.of("app-user")));

        MockHttpServletRequest request = new MockHttpServletRequest("GET", "/api/platform/probe");
        request.addHeader(ServiceAuthenticationFilter.HEADER, "Bearer a-real-user-token");
        MockHttpServletResponse response = new MockHttpServletResponse();
        FilterChain chain = mock(FilterChain.class);

        filter.doFilter(request, response, chain);

        assertThat(response.getStatus()).as("presenting the header is a claim; a wrong claim fails").isEqualTo(401);
        assertThat(filter.refusedCount()).isOne();
    }

    @Test
    @DisplayName("a header that does not verify is refused and counted")
    void anUnverifiableCredentialIsRefused() throws Exception {
        when(decoder.decode(anyString())).thenThrow(new JwtException("bad signature"));

        MockHttpServletRequest request = new MockHttpServletRequest("GET", "/api/platform/probe");
        request.addHeader(ServiceAuthenticationFilter.HEADER, "Bearer forged");
        MockHttpServletResponse response = new MockHttpServletResponse();
        FilterChain chain = mock(FilterChain.class);

        filter.doFilter(request, response, chain);

        assertThat(response.getStatus()).isEqualTo(401);
        assertThat(response.getContentType()).isEqualTo("application/problem+json");
        assertThat(filter.refusedCount()).isOne();
    }

    @Test
    @DisplayName("a malformed header is refused without reaching the decoder")
    void aMalformedHeaderIsRefused() throws Exception {
        MockHttpServletRequest request = new MockHttpServletRequest("GET", "/api/platform/probe");
        request.addHeader(ServiceAuthenticationFilter.HEADER, "not-a-bearer-token");
        MockHttpServletResponse response = new MockHttpServletResponse();
        FilterChain chain = mock(FilterChain.class);

        filter.doFilter(request, response, chain);

        assertThat(response.getStatus()).isEqualTo(401);
        assertThat(filter.refusedCount()).isOne();
    }

    @Test
    @DisplayName("the service identity does not survive onto the next request on a pooled thread")
    void theContextIsClearedAfterTheChain() throws Exception {
        when(decoder.decode(anyString())).thenReturn(jwtWithRealmRoles("svc-core", List.of("svc-caller")));

        MockHttpServletRequest request = new MockHttpServletRequest("GET", "/api/platform/probe");
        request.addHeader(ServiceAuthenticationFilter.HEADER, "Bearer whatever");
        FilterChain chain = mock(FilterChain.class);

        filter.doFilter(request, new MockHttpServletResponse(), chain);

        assertThat(SecurityContextHolder.getContext().getAuthentication())
            .as("a leaked service identity is the next request's identity")
            .isNull();
    }
}
