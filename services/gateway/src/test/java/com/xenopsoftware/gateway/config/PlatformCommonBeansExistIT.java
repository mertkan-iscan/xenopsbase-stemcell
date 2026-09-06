package com.xenopsoftware.gateway.config;

import static org.assertj.core.api.Assertions.assertThat;

import com.xenopsoftware.common.aop.logging.LoggingAspect;
import com.xenopsoftware.common.outbox.OutboxService;
import com.xenopsoftware.gateway.IntegrationTest;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.WebApplicationType;
import org.springframework.context.ApplicationContext;
import org.springframework.web.reactive.DispatcherHandler;

/**
 * The gateway gets the stack-neutral half of the platform, and nothing else (ADR-0017).
 *
 * <p>Two directions, and the second is the one that matters. Core's twin of this test asserts that
 * the shared beans are present; this one also asserts that the SERVLET half is not — because the
 * way this module breaks is by gaining something, not by losing it.
 */
@IntegrationTest
class PlatformCommonBeansExistIT {

    @Autowired
    private ApplicationContext context;

    @Test
    void theStackNeutralModuleContributesItsBeans() {
        // The logging aspect is profile-gated, so the assertion is on the CLASS being reachable
        // and the module being on the classpath rather than on a bean existing in every profile.
        assertThat(LoggingAspect.class.getPackageName()).isEqualTo("com.xenopsoftware.common.aop.logging");
        assertThat(context.getBeansOfType(com.xenopsoftware.common.config.LoggingConfiguration.class))
            .as("the shared logging configuration, contributed by auto-configuration")
            .hasSize(1);
    }

    /**
     * The outbox lives in {@code platform-common}, which this module depends on, and its beans are
     * behind {@code @ConditionalOnBean(EntityManagerFactory.class)}. The gateway has no persistence
     * unit, so it must get the shared contract and none of the persistence.
     *
     * <p>If this starts failing, the optional-dependency marking in platform-common's pom has been
     * lost and the gateway is carrying Hibernate.
     */
    @Test
    void theOutboxIsAbsentBecauseThisProcessHasNoDatabase() {
        assertThat(context.getBeansOfType(OutboxService.class)).isEmpty();
    }

    /**
     * THE ASSERTION THE WHOLE MODULE SPLIT EXISTS FOR.
     *
     * <p>Spring Cloud Gateway runs on WebFlux and nothing else. The enforcer rules in this module's
     * pom and in platform-common's keep the servlet stack off this classpath; this is the runtime
     * proof that they worked, stated as a fact about the context rather than about a dependency
     * tree.
     */
    @Test
    void thisProcessIsReactiveAndHasNoServletHalfOnItsClasspath() {
        assertThat(context.getBeansOfType(DispatcherHandler.class))
            .as("WebFlux, which is the only stack Spring Cloud Gateway runs on")
            .isNotEmpty();

        assertThat(classIsPresent("org.springframework.web.servlet.DispatcherServlet"))
            .as("spring-webmvc here is what makes Boot resolve the application type as %s", WebApplicationType.SERVLET)
            .isFalse();

        assertThat(classIsPresent("com.xenopsoftware.common.web.filter.CorrelationIdFilter"))
            .as("platform-common-web must never reach the gateway; it has a reactive twin instead")
            .isFalse();
    }

    private static boolean classIsPresent(String name) {
        try {
            Class.forName(name, false, PlatformCommonBeansExistIT.class.getClassLoader());
            return true;
        } catch (ClassNotFoundException e) {
            return false;
        }
    }
}
