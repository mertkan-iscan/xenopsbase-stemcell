package com.xenopsoftware.core.service.outbox;

import com.xenopsoftware.core.domain.OutboxMessage;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * The default destination: a log line (T-3.10).
 *
 * <p>Not a placeholder to be embarrassed about. The outbox's guarantee is that a message is
 * RECORDED atomically with its change; where it is delivered is a separate decision this template
 * has no basis to make. Logging makes the mechanism observable end to end without inventing a
 * broker dependency.
 *
 * <p><b>Not a Spring bean, deliberately.</b> The obvious spelling — {@code @Service} plus
 * {@code @ConditionalOnMissingBean} — does not work and does not say so. That annotation is
 * specified for auto-configuration classes, where ordering relative to user beans is defined.
 * On a component-scanned class the condition is evaluated mid-scan, before all definitions exist,
 * and the outcome is undefined; here it removed the bean entirely and the application failed to
 * start with "No qualifying bean of type MessagePublisher".
 *
 * <p>{@link OutboxRelay} instead resolves it through an {@code ObjectProvider} and falls back to
 * this. A fork replaces the destination by declaring any {@link MessagePublisher} bean — no
 * configuration flag, nothing to delete here, and no dependence on bean ordering.
 */
public class LoggingMessagePublisher implements MessagePublisher {

    private static final Logger LOG = LoggerFactory.getLogger(LoggingMessagePublisher.class);

    @Override
    public void publish(OutboxMessage message) {
        LOG.info(
            "outbox published type={} aggregate={}:{} correlationId={} payload={}",
            message.getMessageType(),
            message.getAggregateType(),
            message.getAggregateId(),
            message.getCorrelationId(),
            message.getPayload()
        );
    }
}
