package com.xenopsoftware.core.web.rest;

import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.xenopsoftware.common.idempotency.IdempotencyRecordRepository;
import com.xenopsoftware.core.config.SecurityConfiguration;
import com.xenopsoftware.core.platform.PlatformIdentityResource;
import com.xenopsoftware.core.platform.PlatformProbeRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.webmvc.test.autoconfigure.WebMvcTest;
import org.springframework.context.annotation.Import;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.security.test.context.support.WithAnonymousUser;
import org.springframework.security.test.context.support.WithMockUser;
import org.springframework.test.context.TestPropertySource;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;

/**
 * The SECURITY slice: who may reach these endpoints, with the web layer mocked out (T-5.2).
 *
 * <p>This is the assertion T-5.1 named as the widest hole in the strategy — <i>"nothing anywhere
 * asserts that an unprivileged user is refused an admin endpoint"</i>. It was true: the authorization
 * rules in {@code SecurityConfiguration} were exercised by no test at either service, and every
 * authorization defect this project has hit would have gone unnoticed by the suite.
 *
 * <p><b>Both directions, always.</b> A 403 for an unprivileged caller only shows the check fires. It
 * does not show a privileged caller gets through, and a rule that denies everybody looks identical
 * to one that works — the same reasoning that put a second `smoke-admin` account in the dev realm.
 *
 * <p>Filters are ON here. That is what makes this a security slice rather than a web slice, and it
 * is why the file exists separately: this one fails only for authorization reasons.
 *
 * <p>The subject moved from {@code ExampleItemResource} to {@link PlatformIdentityResource} when the
 * demo domain was deleted (T-9.2). It had to move rather than go with it: {@code /api/admin/**} is
 * the only place the ADMIN rule in {@code SecurityConfiguration} is asserted at all, and deleting
 * the endpoint would have deleted the assertion along with it — silently, since a rule nothing
 * reaches passes every test there is.
 */
// IMPORTING THE REAL SecurityConfiguration IS THE POINT, AND IT IS EASY TO MISS.
//
// Without it @WebMvcTest applies Boot's default test security, under which every authenticated
// caller reaches everything. The first version of this file asserted a 403 on the admin endpoint
// and got 200: the rule was never loaded, and four of the five tests still passed because
// "anonymous is refused" happens to be the default behaviour too.
//
// A security slice that does not load the security configuration is worse than no security slice.
// It reports green against rules it has never seen.
@Import({
    SecurityConfiguration.class,
    tech.jhipster.config.JHipsterProperties.class,
    com.xenopsoftware.common.web.rest.errors.SecurityProblemSupport.class,
})
@TestPropertySource(properties = "spring.security.oauth2.client.provider.oidc.issuer-uri=http://localhost/realms/test")
@WebMvcTest(controllers = PlatformIdentityResource.class)
class SecurityRulesSliceTest {

    private static final String ADMIN = "app-admin";
    private static final String USER = "app-user";

    @Autowired
    private MockMvc mvc;

    @MockitoBean
    private PlatformProbeRepository repository;

    // @WebMvcTest includes Filter beans, and IdempotencyFilter (T-3.8) needs its repository. Not
    // part of what this slice asserts -- it is here so the slice can start at all.
    @MockitoBean
    private IdempotencyRecordRepository idempotencyRecordRepository;

    // Replaces the real decoder, which resolves its configuration by fetching the issuer over the
    // network at startup. @WithMockUser supplies the authentication here, so nothing decodes a
    // token -- this exists only to stop the context reaching out to an issuer that is not there.
    @MockitoBean
    private JwtDecoder jwtDecoder;

    @BeforeEach
    void repositoryReturnsSomething() {
        when(repository.findAll(org.mockito.ArgumentMatchers.any(org.springframework.data.domain.Pageable.class))).thenReturn(
            org.springframework.data.domain.Page.empty()
        );
    }

    @Test
    @WithAnonymousUser
    @DisplayName("anonymous is refused an authenticated endpoint")
    void anonymousIsRefused() throws Exception {
        mvc.perform(get("/api/whoami")).andExpect(status().isUnauthorized());
    }

    @Test
    @WithMockUser(authorities = USER)
    @DisplayName("a plain user reaches the ordinary endpoint")
    void userReachesOrdinaryEndpoint() throws Exception {
        mvc.perform(get("/api/whoami")).andExpect(status().isOk());
    }

    @Test
    @WithMockUser(authorities = USER)
    @DisplayName("a plain user is REFUSED the admin endpoint — the check that had no test")
    void userIsRefusedAdminEndpoint() throws Exception {
        mvc.perform(get("/api/admin/platform/probe")).andExpect(status().isForbidden());
    }

    @Test
    @WithMockUser(authorities = ADMIN)
    @DisplayName("an admin reaches the admin endpoint, so the rule is not simply denying everyone")
    void adminReachesAdminEndpoint() throws Exception {
        mvc.perform(get("/api/admin/platform/probe")).andExpect(status().isOk());
    }

    @Test
    @WithAnonymousUser
    @DisplayName("anonymous is refused the admin endpoint as 401, not 403")
    void anonymousIsRefusedAdminEndpointAsUnauthorized() throws Exception {
        mvc.perform(get("/api/admin/platform/probe")).andExpect(status().isUnauthorized());
    }
}
