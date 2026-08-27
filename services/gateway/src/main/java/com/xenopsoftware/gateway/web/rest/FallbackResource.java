package com.xenopsoftware.gateway.web.rest;

import io.github.resilience4j.bulkhead.BulkheadFullException;
import io.github.resilience4j.circuitbreaker.CallNotPermittedException;
import io.github.resilience4j.circuitbreaker.CircuitBreakerRegistry;
import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import java.net.ConnectException;
import java.net.URI;
import java.net.UnknownHostException;
import java.util.concurrent.TimeoutException;
import org.springframework.cloud.gateway.support.ServerWebExchangeUtils;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ProblemDetail;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.server.ServerWebExchange;
import reactor.core.publisher.Mono;

/**
 * What a caller receives when a request to a downstream is not answered (T-3.9, T-5.11).
 *
 * <p>Without this the {@code CircuitBreaker} filter has nowhere to send a rejected request, and the
 * caller gets Spring's generic error representation — which says nothing about why, and nothing
 * about whether retrying is worth it. Rejection by a resilience control is one of the few failures
 * where the server genuinely knows the answer to "should I try again, and when", so it should say
 * so.
 *
 * <h2>503, not 500</h2>
 *
 * The gateway is working. The downstream is not, or is not being called. A 500 would attribute the
 * failure to the wrong service and send whoever is debugging to the wrong logs.
 *
 * <h2>Why the body is no longer a constant (T-5.11)</h2>
 *
 * It used to be. Every fallback said "its circuit is open. The request was not forwarded, so it had
 * no effect", for every reason the filter falls back — including the TimeLimiter firing, where the
 * request may well have reached the downstream and committed. <b>"It had no effect" is the one part
 * of this body a caller acts on, and it was not always true.</b>
 *
 * <p>Three causes now reach here and they are genuinely different failures:
 *
 * <ul>
 *   <li>{@link BulkheadFullException} — the gateway refused to start the call because it is already
 *       running as many as it admits. Nothing was sent. This is the healthy shedding path added in
 *       T-5.11 and it is expected under overload, not a fault.
 *   <li>{@link CallNotPermittedException} — the circuit is open. Nothing was sent.
 *   <li>A refused connection or an unresolvable name — the call never started. Nothing was sent.
 *   <li>A timeout, or anything else — the call WAS sent and did not come back. The gateway cannot
 *       tell from here whether it committed, so it must not claim it did not.
 * </ul>
 *
 * <p>The first three can promise the caller the request had no effect. The last cannot, and that
 * distinction is the whole point: it is what decides whether replaying is safe.
 */
@RestController
@RequestMapping("/fallback")
public class FallbackResource {

    /**
     * The route filter's {@code name: core} and the resilience4j instance of the same name. Used
     * here to read {@code waitDurationInOpenState} back off the live configuration rather than
     * restating it — the previous constant said ten seconds for months after the value became two
     * (T-5.10), telling every client to come back five times later than necessary.
     */
    private static final String CORE = "core";

    /**
     * A bulkhead permit is released the moment an in-flight call completes, so the condition clears
     * in milliseconds, not seconds. This is a floor that keeps a rejected client from retrying
     * straight back into a full bulkhead and adding to the load that filled it — not an estimate of
     * how long the overload lasts.
     */
    private static final long BULKHEAD_RETRY_AFTER_SECONDS = 1;

    private static final URI TYPE = URI.create("https://datatracker.ietf.org/doc/html/rfc9110#section-15.6.4");

    private final CircuitBreakerRegistry circuitBreakerRegistry;
    private final MeterRegistry meterRegistry;

    public FallbackResource(CircuitBreakerRegistry circuitBreakerRegistry, MeterRegistry meterRegistry) {
        this.circuitBreakerRegistry = circuitBreakerRegistry;
        this.meterRegistry = meterRegistry;
    }

    /**
     * Deliberately unrestricted by method. A circuit opens for the service, not for a verb, so a
     * short-circuited DELETE needs this answer as much as a GET does.
     *
     * <p>Stacking {@code @GetMapping}, {@code @PostMapping} and friends on one method compiles and
     * does not work: Spring resolves a single mapping annotation per method, so the others are
     * silently ignored and every verb but one falls through to a 405 in place of the fallback.
     */
    @RequestMapping("/core")
    public Mono<ResponseEntity<ProblemDetail>> core(ServerWebExchange exchange) {
        // Set by SpringCloudCircuitBreakerFilterFactory immediately before it forwards here, so
        // the fallback sees the actual cause rather than having to guess it. Null is possible --
        // a direct request to /fallback/core, or a future filter that forwards without setting it
        // -- and is treated as the unknown-outcome case, which is the safe direction to be wrong in.
        Throwable cause = exchange.getAttribute(ServerWebExchangeUtils.CIRCUITBREAKER_EXECUTION_EXCEPTION_ATTR);
        return Mono.just(unavailable(CORE, cause));
    }

    private ResponseEntity<ProblemDetail> unavailable(String service, Throwable cause) {
        Reason reason = Reason.of(cause);
        // A control nobody can count is a control nobody notices working -- which is most of how
        // the bulkhead sat at its declared ceiling through a 2000 req/s run without comment
        // (T-5.11). Resilience4j publishes a bulkhead's AVAILABLE PERMITS and nothing about
        // rejections, so a scrape can only catch shedding if it happens to land mid-refusal. This
        // counter is the missing half, and splitting it by reason is the point of it: shedding and
        // an open circuit are opposite diagnoses, and they arrive at the same 503.
        Counter.builder("gateway.fallback")
            .description("Requests answered by a fallback instead of by the downstream")
            .tag("service", service)
            .tag("reason", reason.tag)
            .register(meterRegistry)
            .increment();

        ProblemDetail problem = ProblemDetail.forStatus(HttpStatus.SERVICE_UNAVAILABLE);
        problem.setType(TYPE);
        problem.setTitle("Service unavailable");
        problem.setDetail(reason.detail(service));

        return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE)
            .header(HttpHeaders.RETRY_AFTER, String.valueOf(retryAfterSecondsFor(service, reason)))
            .contentType(MediaType.APPLICATION_PROBLEM_JSON)
            .body(problem);
    }

    /**
     * Why a request ended up here. Classified once, then used for all three answers — the body, the
     * {@code Retry-After} and the counter — so those cannot disagree with each other about what
     * happened.
     */
    private enum Reason {
        /**
         * The gateway refused to start the call because it is already running as many as it
         * admits. Expected under overload, and not a fault: this is the system shedding.
         */
        BULKHEAD_FULL("bulkhead_full"),
        /** The circuit is open. Nothing was sent. */
        CIRCUIT_OPEN("circuit_open"),
        /** The connection was refused or the name did not resolve. The call never started. */
        UNREACHABLE("unreachable"),
        /** The call was sent and did not come back in time. The outcome is genuinely unknown. */
        TIMEOUT("timeout"),
        /** Anything else, including a fallback reached with no recorded cause. */
        UNKNOWN("unknown");

        private final String tag;

        Reason(String tag) {
            this.tag = tag;
        }

        static Reason of(Throwable cause) {
            if (isCausedBy(cause, BulkheadFullException.class)) {
                return BULKHEAD_FULL;
            }
            if (isCausedBy(cause, CallNotPermittedException.class)) {
                return CIRCUIT_OPEN;
            }
            if (isCausedBy(cause, ConnectException.class) || isCausedBy(cause, UnknownHostException.class)) {
                return UNREACHABLE;
            }
            if (isCausedBy(cause, TimeoutException.class)) {
                return TIMEOUT;
            }
            return UNKNOWN;
        }

        String detail(String service) {
            return switch (this) {
                // "Had no effect" is the part a caller acts on, and for the first three it is
                // unambiguous: the call was never started.
                case BULKHEAD_FULL -> "The gateway is already running as many concurrent requests to the %s service as it will admit, and refused this one so the requests in flight stay answerable. It was not forwarded, so it had no effect.".formatted(
                    service
                );
                case CIRCUIT_OPEN -> "The %s service is not responding and its circuit is open. The request was not forwarded, so it had no effect.".formatted(
                    service
                );
                case UNREACHABLE -> "The %s service could not be reached. The request was not forwarded, so it had no effect.".formatted(
                    service
                );
                // The honest answer, and the reason this classification exists at all. A timed-out
                // request may have reached the service and committed; the gateway cannot tell from
                // here, so it must not say.
                case TIMEOUT -> "The %s service did not answer within the time the gateway allows. The request WAS forwarded, so it may have taken effect — do not replay it unless it is idempotent or carries an Idempotency-Key.".formatted(
                    service
                );
                case UNKNOWN -> "The %s service could not be reached. The request may or may not have taken effect.".formatted(service);
            };
        }
    }

    private long retryAfterSecondsFor(String service, Reason reason) {
        if (reason == Reason.BULKHEAD_FULL) {
            return BULKHEAD_RETRY_AFTER_SECONDS;
        }
        // Every other reason either is an open circuit or is one of the failures that opens one, so
        // the breaker's own open-state duration is the honest "come back after". Read from the live
        // config so the two cannot drift apart again.
        long waitMillis = circuitBreakerRegistry
            .circuitBreaker(service)
            .getCircuitBreakerConfig()
            .getWaitIntervalFunctionInOpenState()
            .apply(1);
        // Retry-After is whole seconds. Round UP: telling a client to return while the circuit is
        // still open guarantees it is rejected again.
        return Math.max(1, (waitMillis + 999) / 1000);
    }

    /**
     * Walks the cause chain. The transport wraps its failures — a refused connection arrives as
     * Netty's {@code AnnotatedConnectException} nested inside whatever the proxy filter raised — so
     * an {@code instanceof} on the top-level throwable classifies the common cases wrongly.
     */
    private static boolean isCausedBy(Throwable cause, Class<? extends Throwable> type) {
        for (Throwable current = cause; current != null; current = current.getCause()) {
            if (type.isInstance(current)) {
                return true;
            }
            if (current.getCause() == current) {
                break;
            }
        }
        return false;
    }
}
