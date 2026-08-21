package com.xenopsoftware.gateway.config;

import org.springframework.beans.factory.config.BeanPostProcessor;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.data.redis.connection.lettuce.LettuceConnectionFactory;

/**
 * Opens the Valkey connection at startup instead of inside the first request (T-2.11).
 *
 * <h2>The problem this removes</h2>
 *
 * Lettuce connects lazily. The first session write therefore establishes the connection, and
 * establishing it <em>blocks</em> — {@code ReactiveRedisTemplate.doInConnection} parks while the
 * socket and the protocol handshake come up.
 *
 * <p>In this gateway the first session write happens during the response commit, so the block lands
 * on an event-loop thread. BlockHound reported it as
 * {@code BlockingOperationError: Blocking call! jdk.internal.misc.Unsafe#park} from a redirect and
 * as a 500 from the logout endpoint — mentioning neither Redis nor sessions, several layers from
 * the cause.
 *
 * <p>BlockHound is only present in tests. Without it the same block still happens in production; it
 * simply stalls an event-loop thread quietly instead of failing loudly, which is the worse of the
 * two.
 *
 * <h2>Why this rather than an allowlist entry</h2>
 *
 * Allowlisting the frame was tried first and is the wrong shape: it tells the detector to ignore a
 * real blocking call on a real event loop, so the test goes green and production keeps the stall.
 * Connecting at startup means the blocking happens once, on the main thread, where blocking is
 * expected.
 *
 * <h2>What this commits us to</h2>
 *
 * The gateway now fails to start if Valkey is unreachable, rather than starting and failing on the
 * first login. That is deliberate: a gateway with no session store cannot authenticate anybody, so
 * "running" would be a false statement about it. It does mean Valkey is on the startup path, and a
 * Valkey outage is a gateway outage — which is true either way, just visible sooner.
 *
 * <p>A {@code BeanPostProcessor} because {@code eagerInitialization} is a property of the
 * connection factory and Spring Boot exposes no configuration key for it.
 */
@Configuration
public class RedisEagerConnectionConfiguration {

    /**
     * {@code static}, and that is load-bearing rather than stylistic. A non-static
     * {@code BeanPostProcessor} factory method forces its enclosing configuration class to be
     * instantiated very early, before {@code @ConfigurationProperties} binding has necessarily
     * happened, and Spring logs that as an obscure warning about the bean not being eligible for
     * post-processing.
     */
    @Bean
    static BeanPostProcessor eagerLettuceConnection() {
        return new BeanPostProcessor() {
            @Override
            public Object postProcessBeforeInitialization(Object bean, String beanName) {
                if (bean instanceof LettuceConnectionFactory factory) {
                    factory.setEagerInitialization(true);
                }
                return bean;
            }
        };
    }
}
