package com.xenopsoftware.core.config;

import static org.assertj.core.api.Assertions.assertThat;

import com.xenopsoftware.common.config.audit.AuditEventListenerRegistrar;
import com.xenopsoftware.common.config.audit.AuditLogWriter;
import com.xenopsoftware.common.idempotency.IdempotencyFilter;
import com.xenopsoftware.common.outbox.OutboxRelay;
import com.xenopsoftware.common.outbox.OutboxService;
import com.xenopsoftware.common.security.SpringSecurityAuditorAware;
import com.xenopsoftware.common.tenancy.DefaultTenantResolver;
import com.xenopsoftware.common.web.filter.CorrelationIdFilter;
import com.xenopsoftware.common.web.filter.CorrelationIdObservationFilter;
import com.xenopsoftware.common.web.rest.errors.ExceptionTranslator;
import com.xenopsoftware.common.web.rest.errors.SecurityProblemSupport;
import com.xenopsoftware.core.IntegrationTest;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.context.ApplicationContext;

/**
 * The shared modules' beans exist in this service (ADR-0017).
 *
 * <h2>Why a test for something so obvious</h2>
 *
 * Because its failure mode is absence, and absence produces no error. These classes live in
 * {@code com.xenopsoftware.common}, outside this application's {@code @ComponentScan} root, and are
 * contributed by auto-configuration. Break that — a typo in
 * {@code AutoConfiguration.imports}, a condition that turns out never to be true, a dependency that
 * stops being on the classpath — and the application starts perfectly. There is no correlation id
 * on any log line, no idempotency replay, no audit columns, and errors come back in Boot's default
 * shape instead of the problem-detail shape the API contract promises. Every existing test still
 * passes, because none of them assert the beans are there.
 *
 * <p>That is not hypothetical. The product this template is forked into shipped a tenant status
 * gate whose {@code @ConditionalOnBean} was evaluated too early on a component-scanned class, so
 * the condition was always false and the bean never existed in any service but one. It was found
 * much later, by an unrelated task.
 *
 * <p>So: a list of beans, asserted by type. Adding a bean to a shared module means adding a line
 * here, which is the cheapest possible reminder that a service has to be able to see it.
 */
@IntegrationTest
class PlatformCommonBeansExistIT {

    @Autowired
    private ApplicationContext context;

    @Test
    void theStackNeutralModuleContributesItsBeans() {
        assertThat(context.getBeansOfType(OutboxService.class)).as("the outbox writer").hasSize(1);
        assertThat(context.getBeansOfType(OutboxRelay.class)).as("the outbox relay").hasSize(1);
    }

    @Test
    void theServletModuleContributesItsBeans() {
        assertThat(context.getBeansOfType(CorrelationIdFilter.class)).as("correlation id on every log line").hasSize(1);
        assertThat(context.getBeansOfType(CorrelationIdObservationFilter.class)).as("correlation id on the span").hasSize(1);
        assertThat(context.getBeansOfType(ExceptionTranslator.class)).as("the problem-detail error shape").hasSize(1);
        assertThat(context.getBeansOfType(SecurityProblemSupport.class)).as("401 and 403 as problem details").hasSize(1);
        assertThat(context.getBeansOfType(DefaultTenantResolver.class)).as("the tenant discriminator").hasSize(1);
        assertThat(context.getBeansOfType(IdempotencyFilter.class)).as("replay instead of a duplicate write").hasSize(1);
        assertThat(context.getBeansOfType(AuditLogWriter.class)).as("the audit log").hasSize(1);
        assertThat(context.getBeansOfType(AuditEventListenerRegistrar.class)).as("what drives the audit log").hasSize(1);
    }

    /**
     * By NAME, not only by type. {@code @EnableJpaAuditing(auditorAwareRef = "springSecurityAuditorAware")}
     * in {@link DatabaseConfiguration} resolves the auditor by bean name, so renaming the factory
     * method in the shared module would leave auditing pointing at a bean that does not exist —
     * and the symptom is null {@code created_by} columns rather than a failure.
     */
    @Test
    void theAuditorIsRegisteredUnderTheNameJpaAuditingAsksFor() {
        assertThat(context.containsBean("springSecurityAuditorAware")).isTrue();
        assertThat(context.getBean("springSecurityAuditorAware")).isInstanceOf(SpringSecurityAuditorAware.class);
    }
}
