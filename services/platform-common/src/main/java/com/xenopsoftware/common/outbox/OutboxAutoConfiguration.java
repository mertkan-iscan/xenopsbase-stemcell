package com.xenopsoftware.common.outbox;

import com.fasterxml.jackson.databind.ObjectMapper;
import io.nats.client.Connection;
import jakarta.persistence.EntityManagerFactory;
import javax.sql.DataSource;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.AutoConfiguration;
import org.springframework.boot.autoconfigure.condition.ConditionalOnBean;
import org.springframework.boot.autoconfigure.condition.ConditionalOnClass;
import org.springframework.boot.autoconfigure.condition.ConditionalOnMissingBean;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.boot.hibernate.autoconfigure.HibernateJpaAutoConfiguration;
import org.springframework.context.annotation.Bean;

/**
 * Wires the transactional outbox for any service that has a JPA persistence unit (T-3.10).
 *
 * <h2>Why this is an auto-configuration and not a {@code @Configuration}</h2>
 *
 * {@link OutboxService} and {@link OutboxRelay} were {@code @Service} beans under
 * {@code com.xenopsoftware.core}. They are now under {@code com.xenopsoftware.common}, which is
 * not under any service's scan root, so component scanning would not find them — <b>and would not
 * say so</b>. The beans would simply not exist, every {@code @ConditionalOnBean} downstream of
 * them would silently evaluate false, and the first sign of it would be an outbox that records
 * nothing while the application starts cleanly.
 *
 * <p>Widening a service's {@code @ComponentScan} to {@code com.xenopsoftware} would also work and
 * is the wrong fix: it re-couples the modules and defeats the dependency rules that keep the
 * gateway free of a servlet stack. Auto-configuration is how a library contributes beans without
 * the including application knowing its package layout (ADR-0017).
 *
 * <h2>{@code @ConditionalOnBean} is safe HERE, and is not on a scanned bean</h2>
 *
 * The condition below is evaluated after {@link HibernateJpaAutoConfiguration} has contributed its
 * {@code EntityManagerFactory}, because auto-configuration ordering is defined and scan ordering
 * is not. The same annotation on a component-scanned class is evaluated mid-scan, before the beans
 * it asks about exist, and is therefore always false — which is exactly how a sibling product
 * shipped a tenant status gate that never once ran. Declared here, "no persistence unit" really
 * does mean "no outbox", and the gateway gets neither.
 *
 * <h2>What the including service still has to do</h2>
 *
 * Declare the packages. {@link OutboxMessage} is an entity and {@link OutboxMessageRepository} is a
 * Spring Data repository, and neither is under the service's own {@code @SpringBootApplication}
 * package, so the service's {@code DatabaseConfiguration} names this module in its
 * {@code @EntityScan} and {@code @EnableJpaRepositories}. That is deliberately NOT done from here:
 * an {@code @EntityScan} anywhere <em>replaces</em> the application's default entity packages
 * rather than adding to them, so a library that declared one would silently stop the service's own
 * entities from being found. Forgetting the service-side declaration fails loudly at startup —
 * "Not a managed type" — which is the failure mode worth having.
 */
@AutoConfiguration(after = HibernateJpaAutoConfiguration.class)
@ConditionalOnBean(EntityManagerFactory.class)
public class OutboxAutoConfiguration {

    @Bean
    @ConditionalOnMissingBean
    public OutboxService outboxService(OutboxMessageRepository repository, ObjectMapper objectMapper) {
        return new OutboxService(repository, objectMapper);
    }

    /**
     * The publisher is still resolved through an {@link ObjectProvider} inside {@link OutboxRelay}
     * rather than being injected here, so a fork replaces the destination by declaring any
     * {@link MessagePublisher} bean and nothing in this module has to change.
     */
    @Bean
    @ConditionalOnMissingBean
    public OutboxRelay outboxRelay(OutboxMessageRepository repository, ObjectProvider<MessagePublisher> publisher) {
        return new OutboxRelay(repository, publisher);
    }

    /**
     * The scheduled drain (T-9.6, ADR-0018). Nothing called {@link OutboxRelay#relayBatch()} until
     * this existed, which made the whole outbox inert in every environment since T-3.10.
     *
     * <p>Conditional on a property so a fork can turn it off, defaulting to ON — which is the
     * opposite of how the other seams here default, and deliberately so. An outbox that records and
     * never delivers is not a disabled feature, it is a broken one, and the version of this that
     * defaulted to off would have shipped the same silence with a flag to explain it.
     */
    @Bean
    @ConditionalOnMissingBean
    @ConditionalOnProperty(name = "platform.outbox.relay.enabled", havingValue = "true", matchIfMissing = true)
    public OutboxRelayScheduler outboxRelayScheduler(OutboxRelay relay, DataSource dataSource) {
        return new OutboxRelayScheduler(relay, dataSource);
    }

    /**
     * NATS, when the service has a connection and has been told to use it (ADR-0018).
     *
     * <p>Two conditions and both are load-bearing. {@code @ConditionalOnClass} because jnats is an
     * OPTIONAL dependency of this module — a service that does not want a broker must not fail to
     * start over a missing class. {@code @ConditionalOnProperty} because a service can have jnats on
     * its classpath and still want the logging publisher, and a broker chosen by classpath rather
     * than by configuration is a decision nobody made.
     *
     * <p>{@link LoggingMessagePublisher} remains the default, resolved by {@link OutboxRelay}
     * through an {@code ObjectProvider}, so a fork with no broker still builds, starts and passes
     * its tests.
     */
    @Bean
    @ConditionalOnMissingBean(MessagePublisher.class)
    @ConditionalOnClass(Connection.class)
    @ConditionalOnProperty(name = "platform.outbox.publisher", havingValue = "nats")
    public MessagePublisher natsPublisher(Connection connection, @Value("${platform.outbox.subject-prefix:}") String subjectPrefix) {
        return new NatsPublisher(connection, subjectPrefix);
    }
}
