package com.xenopsoftware.common.outbox;

import io.nats.client.Connection;
import io.nats.client.ConnectionListener;
import io.nats.client.Nats;
import io.nats.client.Options;
import java.time.Duration;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.AutoConfiguration;
import org.springframework.boot.autoconfigure.condition.ConditionalOnClass;
import org.springframework.boot.autoconfigure.condition.ConditionalOnMissingBean;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Bean;

/**
 * The NATS connection, for services that publish (T-9.6, ADR-0018).
 *
 * <p>Written here because Spring Boot has no NATS auto-configuration; the alternative is every
 * service building a connection at a call site with its own idea of what the timeouts should be.
 *
 * <h2>It does not fail startup when the broker is absent</h2>
 *
 * That is the decision worth stating, because the opposite is the obvious one. {@code Nats.connect}
 * with default options throws when nothing is listening, which would make a service refuse to start
 * because a BACKGROUND path is unavailable — the outbox is drained after the fact and the caller has
 * already been answered. A service that cannot serve requests because it cannot publish events has
 * inverted its own priorities.
 *
 * <p>So the connection reconnects forever and starts even if the first attempt fails. What that
 * costs: a broker that is down looks like a working system with a growing {@code outbox_message}
 * table. {@code OutboxRelay} records the failure per message in {@code last_error} and the relay
 * keeps retrying, so the evidence is in the table rather than in a startup crash. Alert on unpublished
 * age, not on process health.
 *
 * <p>Contrast with {@code RedisEagerConnectionConfiguration} in the gateway, which DOES refuse to
 * start: a session store is on the request path, and a gateway that cannot hold a session cannot
 * serve anyone. The difference is which path the dependency is on, and it is why these two
 * deliberately disagree.
 */
@AutoConfiguration
@ConditionalOnClass(Connection.class)
@ConditionalOnProperty(name = "platform.outbox.publisher", havingValue = "nats")
public class NatsConnectionConfiguration {

    private static final Logger LOG = LoggerFactory.getLogger(NatsConnectionConfiguration.class);

    /**
     * {@code destroyMethod = "close"} so the connection drains and closes on shutdown rather than
     * being severed. A NATS publish is asynchronous by default: without a clean close, whatever is
     * still in the outbound buffer at SIGTERM is dropped. Those messages are still in the outbox
     * unpublished, so nothing is lost — but they are republished on the next pass rather than
     * arriving now, which is a needless duplicate for every consumer.
     */
    @Bean(destroyMethod = "close")
    @ConditionalOnMissingBean
    public Connection natsConnection(
        @Value("${platform.outbox.nats.url:nats://localhost:4222}") String url,
        @Value("${spring.application.name:unknown}") String applicationName,
        @Value("${platform.outbox.subject-prefix:}") String subjectPrefix
    ) throws Exception {
        Options options = new Options.Builder()
            .server(url)
            // Named, so `nats server report connections` on the broker says which service is
            // connected rather than listing anonymous clients. Costs nothing and is the difference
            // between diagnosable and not.
            .connectionName(applicationName)
            .maxReconnects(-1)
            .reconnectWait(Duration.ofSeconds(2))
            .connectionTimeout(Duration.ofSeconds(5))
            // THE LINE THAT MAKES STARTUP SURVIVE AN ABSENT BROKER. Without it, connect() throws
            // when nothing is listening and the whole context fails -- for a background path.
            .noRandomize()
            // THE TOPOLOGY IS APPLIED FROM THE LISTENER, not once after connect, because this
            // connection is allowed to start disconnected (see below). A stream declared only at
            // startup would never be declared at all on the run where the broker came up second --
            // and that run looks identical to a healthy one until a consumer finds nothing.
            //
            // Every reconnect re-applies it. Streams.apply creates what is missing and updates what
            // drifted, so doing it repeatedly costs one round trip and converges the broker on the
            // file rather than on whatever the last operator did.
            .connectionListener((connection, event) -> {
                LOG.info("NATS connection {}: {}", event, connection.getConnectedUrl());
                if (event == ConnectionListener.Events.CONNECTED || event == ConnectionListener.Events.RECONNECTED) {
                    try {
                        Streams.apply(connection.jetStreamManagement(), subjectPrefix);
                    } catch (Exception e) {
                        // Logged, not thrown. This runs on the client's callback thread, where a
                        // throw would be swallowed by the library anyway, and the publish path
                        // already fails loudly on a missing stream -- an acknowledged publish
                        // cannot succeed without one. So the visible failure stays where it can be
                        // acted on: the outbox row keeps its last_error and the relay retries.
                        LOG.error("Could not declare the JetStream topology; publishes will fail until this is fixed", e);
                    }
                }
            })
            .errorListener(
                new io.nats.client.ErrorListener() {
                    @Override
                    public void errorOccurred(Connection connection, String error) {
                        LOG.warn("NATS error: {}", error);
                    }

                    @Override
                    public void exceptionOccurred(Connection connection, Exception exception) {
                        LOG.warn("NATS exception", exception);
                    }
                }
            )
            .build();

        try {
            return Nats.connect(options);
        } catch (Exception e) {
            // Reconnecting forever is only useful if there is a connection object to reconnect
            // WITH. A first attempt that fails outright leaves nothing, so this falls back to a
            // connection that starts disconnected and dials in the background.
            LOG.warn("NATS is not reachable at {} yet; starting anyway and reconnecting in the background: {}", url, e.getMessage());
            return Nats.connectReconnectOnConnect(options);
        }
    }
}
