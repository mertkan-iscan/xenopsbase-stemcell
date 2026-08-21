package com.xenopsoftware.core.web.rest;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.xenopsoftware.core.IntegrationTest;
import com.xenopsoftware.core.security.AuthoritiesConstants;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors;
import org.springframework.test.web.servlet.MockMvc;

/**
 * The infrastructure usage endpoint (T-3.16).
 *
 * <p>Both assertions target a way this can fail <em>quietly</em> rather than the happy path, which
 * needs a Prometheus and is covered by using the thing.
 */
@IntegrationTest
@org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc
class InfraUsageResourceIT {

    private static final String PATH = "/api/admin/infra/usage";

    @Autowired
    private MockMvc mockMvc;

    /**
     * The endpoint lists every container, its limits and its volumes, which is a map of the
     * infrastructure. An ordinary application user has no reason to read it.
     *
     * <p>This asserts the rule that actually protects it. The frontend also hides the panel from
     * non-admins, and that is a courtesy which anyone can undo with dev tools — if this rule ever
     * stopped applying, nothing else would notice.
     */
    @Test
    void anOrdinaryUserCannotReadInfrastructureUsage() throws Exception {
        mockMvc
            .perform(
                get(PATH)
                    .with(SecurityMockMvcRequestPostProcessors.jwt().authorities(new SimpleGrantedAuthority(AuthoritiesConstants.USER)))
            )
            .andExpect(status().isForbidden());
    }

    /**
     * With no Prometheus configured — which is the default, and the case in this test context — the
     * endpoint says so.
     *
     * <p>The failure this guards against is returning 200 with empty lists. A dashboard rendering
     * zero containers is indistinguishable from a cluster running nothing, and the entire purpose
     * of the view is to tell those apart. 501 rather than 503 because nothing is broken and
     * retrying would not help.
     */
    @Test
    void anUnconfiguredPrometheusIsReportedRatherThanRenderedAsZero() throws Exception {
        mockMvc
            .perform(
                get(PATH)
                    .with(SecurityMockMvcRequestPostProcessors.jwt().authorities(new SimpleGrantedAuthority(AuthoritiesConstants.ADMIN)))
            )
            .andExpect(status().isNotImplemented())
            .andExpect(jsonPath("$.detail").value(org.hamcrest.Matchers.containsString("prometheus-url")));
    }
}
