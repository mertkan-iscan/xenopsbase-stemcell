package com.xenopsoftware.core.service.outbox;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.xenopsoftware.core.domain.OutboxMessage;
import com.xenopsoftware.core.repository.OutboxMessageRepository;
import org.slf4j.MDC;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

/**
 * Records a message to be published later, atomically with the change it describes (T-3.10).
 *
 * <p>Call this from inside the transaction that makes the change:
 *
 * <pre>
 * &#64;Transactional
 * public Order place(Order order) {
 *     Order saved = repository.save(order);
 *     outbox.record("order.placed", "Order", saved.getId().toString(), saved);
 *     return saved;
 * }
 * </pre>
 *
 * <p>The message and the state change commit together or not at all. Publishing to a broker
 * directly from that method could not offer this: the commit and the publish are two systems, and
 * every ordering of them leaves a window where one happened and the other did not — an event
 * announcing a change that was rolled back, or a change nobody was told about.
 */
@Service
public class OutboxService {

    private final OutboxMessageRepository repository;
    private final ObjectMapper objectMapper;

    public OutboxService(OutboxMessageRepository repository, ObjectMapper objectMapper) {
        this.repository = repository;
        this.objectMapper = objectMapper;
    }

    /**
     * {@code MANDATORY}, deliberately. Calling this outside a transaction throws instead of
     * quietly opening one of its own — which would commit the message independently of the change
     * it describes and silently remove the only guarantee this class provides.
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public OutboxMessage record(String messageType, String aggregateType, String aggregateId, Object payload) {
        OutboxMessage message = new OutboxMessage();
        message.setMessageType(messageType);
        message.setAggregateType(aggregateType);
        message.setAggregateId(aggregateId);
        message.setPayload(serialize(payload));
        // Carried through so a consumer's logs can be joined back to the request that caused the
        // event (T-3.8). Without it the causal chain stops at the transaction boundary.
        message.setCorrelationId(MDC.get("requestId"));
        return repository.save(message);
    }

    private String serialize(Object payload) {
        try {
            return objectMapper.writeValueAsString(payload);
        } catch (JsonProcessingException e) {
            // Failing the whole transaction is correct. A message that cannot be serialised is a
            // change nobody will be told about, and committing the change anyway would make the
            // outbox a best-effort log rather than a guarantee.
            String type = payload == null ? "null" : payload.getClass().getName();
            throw new IllegalArgumentException("Outbox payload of type " + type + " is not serialisable", e);
        }
    }
}
