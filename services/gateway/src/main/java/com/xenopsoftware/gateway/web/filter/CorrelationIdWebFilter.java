package com.xenopsoftware.gateway.web.filter;

import java.util.UUID;
import org.slf4j.MDC;
import org.springframework.core.Ordered;
import org.springframework.http.server.reactive.ServerHttpRequest;
import org.springframework.stereotype.Component;
import org.springframework.web.server.ServerWebExchange;
import org.springframework.web.server.WebFilter;
import org.springframework.web.server.WebFilterChain;
import reactor.core.publisher.Mono;
import reactor.util.context.Context;

/**
 * Assigns a correlation id at the edge and makes it reachable from every log line (T-3.8).
 *
 * <p>Runs first. Anything logged by a filter ordered ahead of this one has no id, so the ordering
 * is the difference between "every log line is correlated" and "most are".
 *
 * <h2>Why the Reactor context rather than just MDC</h2>
 *
 * MDC is a thread-local, and WebFlux hands a single request between threads freely. Setting MDC
 * here and reading it later gives the id on some log lines and not others, depending on which
 * scheduler happened to run that operator — which is worse than not having it, because the gaps
 * are invisible and look like missing requests.
 *
 * <p>So the id goes into the Reactor context, which travels with the request rather than with the
 * thread, and {@code CorrelationIdContextConfiguration} bridges it back into MDC around each
 * operator. That bridge is what makes {@code %X{requestId}} in the log pattern work at all.
 */
@Component
public class CorrelationIdWebFilter implements WebFilter, Ordered {

    @Override
    public int getOrder() {
        return Ordered.HIGHEST_PRECEDENCE;
    }

    @Override
    public Mono<Void> filter(ServerWebExchange exchange, WebFilterChain chain) {
        String inbound = exchange.getRequest().getHeaders().getFirst(CorrelationId.HEADER);
        String id = CorrelationId.isAcceptable(inbound) ? inbound : newId();

        // Written onto the REQUEST, not just held locally: Spring Cloud Gateway forwards request
        // headers to the routed service, so this is what carries the id into core. Held only in
        // the context, the id would stop at this service and each hop would invent its own.
        ServerHttpRequest request = exchange.getRequest().mutate().header(CorrelationId.HEADER, id).build();

        // Echoed so a caller reporting a problem can quote the id from their own response,
        // instead of everyone searching logs by timestamp.
        exchange.getResponse().getHeaders().set(CorrelationId.HEADER, id);

        return (
            chain
                .filter(exchange.mutate().request(request).build())
                .contextWrite(Context.of(CorrelationId.MDC_KEY, id))
                // The context is gone by the time this runs, so the id is captured by the lambda.
                // Without it the completion line -- the one carrying status and duration -- is the
                // single most useful log line and the only one missing its correlation id.
                .doFinally(signal -> MDC.remove(CorrelationId.MDC_KEY))
        );
    }

    /**
     * A UUID without dashes: 32 characters, URL-safe, and short enough to read aloud when
     * someone is quoting it from an error page.
     */
    private static String newId() {
        return UUID.randomUUID().toString().replace("-", "");
    }
}
