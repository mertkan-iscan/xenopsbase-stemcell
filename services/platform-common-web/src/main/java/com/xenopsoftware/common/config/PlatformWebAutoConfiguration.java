package com.xenopsoftware.common.config;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.xenopsoftware.common.config.audit.AuditEventListenerRegistrar;
import com.xenopsoftware.common.config.audit.AuditLogWriter;
import com.xenopsoftware.common.idempotency.IdempotencyFilter;
import com.xenopsoftware.common.idempotency.IdempotencyRecordRepository;
import com.xenopsoftware.common.security.SpringSecurityAuditorAware;
import com.xenopsoftware.common.tenancy.DefaultTenantResolver;
import com.xenopsoftware.common.web.filter.CorrelationIdFilter;
import com.xenopsoftware.common.web.filter.CorrelationIdObservationFilter;
import com.xenopsoftware.common.web.rest.errors.ExceptionTranslator;
import com.xenopsoftware.common.web.rest.errors.SecurityProblemSupport;
import jakarta.persistence.EntityManagerFactory;
import org.springframework.boot.autoconfigure.AutoConfiguration;
import org.springframework.boot.autoconfigure.condition.ConditionalOnBean;
import org.springframework.boot.autoconfigure.condition.ConditionalOnMissingBean;
import org.springframework.boot.hibernate.autoconfigure.HibernateJpaAutoConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.core.env.Environment;
import org.springframework.jdbc.core.JdbcTemplate;

/**
 * Everything the servlet services share, contributed as beans rather than found by a scan
 * (ADR-0017).
 *
 * <h2>The whole reason this file exists</h2>
 *
 * Every class wired below used to carry {@code @Component} or {@code @ControllerAdvice} and live
 * under {@code com.xenopsoftware.core}, where the application's own {@code @ComponentScan} found
 * it. They now live under {@code com.xenopsoftware.common}, which no service scans — and a bean
 * that component scanning does not find is not an error. Nothing logs, nothing fails, the beans
 * are simply absent: no correlation id on any log line, no idempotency replay, no audit columns,
 * and errors rendered by Boot's default handler instead of the problem-detail shape the API
 * contract promises.
 *
 * <p>The alternative fix — widening each service's scan to {@code com.xenopsoftware} — was
 * rejected. It puts the servlet module's classes back inside the gateway's reach and makes the
 * dependency rules that keep the gateway startable a matter of discipline again.
 *
 * <p>{@code PlatformCommonBeansExistTest} in each service asserts these are present, because the
 * failure mode here is absence rather than error and absence is what tests are worst at noticing.
 */
@AutoConfiguration(after = HibernateJpaAutoConfiguration.class)
public class PlatformWebAutoConfiguration {

    @Bean
    @ConditionalOnMissingBean
    public CorrelationIdFilter correlationIdFilter() {
        return new CorrelationIdFilter();
    }

    @Bean
    @ConditionalOnMissingBean
    public CorrelationIdObservationFilter correlationIdObservationFilter() {
        return new CorrelationIdObservationFilter();
    }

    /**
     * The one {@link org.springframework.core.task.TaskDecorator} in this repository.
     *
     * <p>Boot applies a single decorator bean to the executors it builds, which is what makes
     * {@code @Async} carry the correlation id and the tenant. It is contributed here rather than
     * component-scanned for the reason ADR-0017 gives, and it is servlet-side because both values
     * it carries are {@code ThreadLocal}s: the gateway is reactive and bridges the same id through
     * the Reactor context instead.
     */
    @Bean
    @ConditionalOnMissingBean
    public ContextPropagatingTaskDecorator contextPropagatingTaskDecorator() {
        return new ContextPropagatingTaskDecorator();
    }

    @Bean
    @ConditionalOnMissingBean
    public ExceptionTranslator exceptionTranslator(Environment env) {
        return new ExceptionTranslator(env);
    }

    @Bean
    @ConditionalOnMissingBean
    public SecurityProblemSupport securityProblemSupport(ObjectMapper objectMapper) {
        return new SecurityProblemSupport(objectMapper);
    }

    /**
     * Named {@code springSecurityAuditorAware} deliberately: {@code @EnableJpaAuditing} in each
     * service references the auditor by BEAN NAME, and a method name of anything else leaves
     * auditing pointing at a bean that does not exist.
     */
    @Bean
    @ConditionalOnMissingBean
    public SpringSecurityAuditorAware springSecurityAuditorAware() {
        return new SpringSecurityAuditorAware();
    }

    @Bean
    @ConditionalOnMissingBean
    public DefaultTenantResolver defaultTenantResolver() {
        return new DefaultTenantResolver();
    }

    @Bean
    @ConditionalOnMissingBean
    @ConditionalOnBean(EntityManagerFactory.class)
    public IdempotencyFilter idempotencyFilter(IdempotencyRecordRepository repository) {
        return new IdempotencyFilter(repository);
    }

    /**
     * Conditional on the persistence unit, NOT on {@code JdbcTemplate}, and the difference is not
     * cosmetic. {@code @ConditionalOnBean(JdbcTemplate.class)} evaluated false here because
     * {@code JdbcTemplateAutoConfiguration} had not contributed its bean yet, so this bean was
     * skipped while {@link #auditEventListenerRegistrar} — conditional on the entity manager
     * factory, which HAD been contributed — was created and then failed on a missing collaborator.
     *
     * <p>Two conditions in one class that can disagree about whether persistence is present is the
     * bug. Both now ask the same question, and a {@code JdbcTemplate} exists wherever a
     * {@code DataSource} does, which is wherever an {@code EntityManagerFactory} does.
     */
    @Bean
    @ConditionalOnMissingBean
    @ConditionalOnBean(EntityManagerFactory.class)
    public AuditLogWriter auditLogWriter(JdbcTemplate jdbcTemplate) {
        return new AuditLogWriter(jdbcTemplate);
    }

    @Bean
    @ConditionalOnMissingBean
    @ConditionalOnBean(EntityManagerFactory.class)
    public AuditEventListenerRegistrar auditEventListenerRegistrar(EntityManagerFactory entityManagerFactory, AuditLogWriter writer) {
        return new AuditEventListenerRegistrar(entityManagerFactory, writer);
    }
}
