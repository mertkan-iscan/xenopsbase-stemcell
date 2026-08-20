package com.xenopsoftware.gateway.web.rest;

import java.net.URI;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ProblemDetail;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
import reactor.core.publisher.Mono;

/**
 * What a caller receives when a downstream's circuit is open (T-3.9).
 *
 * <p>Without this the {@code CircuitBreaker} filter has nowhere to send a short-circuited request,
 * and the caller gets Spring's generic error representation — which says nothing about why, and
 * nothing about whether retrying is worth it. An open circuit is one of the few failures where the
 * server genuinely knows the answer to "should I try again, and when", so it should say so.
 *
 * <h2>503, not 500</h2>
 *
 * The gateway is working. The downstream is not. A 500 would attribute the failure to the wrong
 * service and send whoever is debugging to the wrong logs.
 *
 * <p>{@code Retry-After} is set because an open circuit has a known duration —
 * {@code waitDurationInOpenState}. Telling a client to come back in ten seconds is strictly better
 * than letting it retry immediately into a breaker that will reject it anyway, and better than a
 * client inventing its own backoff.
 */
@RestController
@RequestMapping("/fallback")
public class FallbackResource {

    /**
     * Matches {@code waitDurationInOpenState} for the {@code core} instance. If one changes and
     * the other does not, clients are told to return either while the circuit is still open, or
     * later than necessary.
     */
    private static final String RETRY_AFTER_SECONDS = "10";

    private static final URI TYPE = URI.create("https://datatracker.ietf.org/doc/html/rfc9110#section-15.6.4");

    /**
     * Deliberately unrestricted by method. A circuit opens for the service, not for a verb, so a
     * short-circuited DELETE needs this answer as much as a GET does.
     *
     * <p>Stacking {@code @GetMapping}, {@code @PostMapping} and friends on one method compiles and
     * does not work: Spring resolves a single mapping annotation per method, so the others are
     * silently ignored and every verb but one falls through to a 405 in place of the fallback.
     */
    @RequestMapping("/core")
    public Mono<ResponseEntity<ProblemDetail>> core() {
        return Mono.just(unavailable("core"));
    }

    private static ResponseEntity<ProblemDetail> unavailable(String service) {
        ProblemDetail problem = ProblemDetail.forStatus(HttpStatus.SERVICE_UNAVAILABLE);
        problem.setType(TYPE);
        problem.setTitle("Service unavailable");
        problem.setDetail(
            "The %s service is not responding and its circuit is open. The request was not forwarded, so it had no effect.".formatted(
                    service
                )
        );
        // "It had no effect" is the part a caller needs. A timeout leaves them unable to tell
        // whether the work happened; a short-circuited request definitively did not.

        return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE)
            .header(HttpHeaders.RETRY_AFTER, RETRY_AFTER_SECONDS)
            .contentType(MediaType.APPLICATION_PROBLEM_JSON)
            .body(problem);
    }
}
