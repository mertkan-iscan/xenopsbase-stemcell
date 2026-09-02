package com.xenopsoftware.gateway.web.rest.errors;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import java.net.URI;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;
import org.springframework.core.env.Environment;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.mock.http.server.reactive.MockServerHttpRequest;
import org.springframework.mock.web.server.MockServerWebExchange;
import org.springframework.web.server.ServerWebExchange;
import tech.jhipster.web.rest.errors.ProblemDetailWithCause;
import tech.jhipster.web.rest.errors.ProblemDetailWithCause.ProblemDetailWithCauseBuilder;

/**
 * The response {@link ExceptionTranslator} actually hands back, as opposed to the problem body it
 * assembles.
 *
 * <p>{@link ExceptionTranslatorIT} exercises this through a running context and therefore only ever
 * along the path a real request takes. The cases here are the ones a real request does not produce
 * on demand — a response that has already started being written, a problem body that arrives with
 * its properties already filled in — and they are exactly the cases where getting it wrong turns one
 * failure into two.
 */
class ExceptionTranslatorResponseUnitTest {

    private final ExceptionTranslator translator = translatorFor("dev");

    private static ExceptionTranslator translatorFor(String... activeProfiles) {
        Environment env = mock(Environment.class);
        when(env.getActiveProfiles()).thenReturn(activeProfiles);
        return new ExceptionTranslator(env);
    }

    private static MockServerWebExchange anyRequest() {
        return MockServerWebExchange.from(MockServerHttpRequest.get("/services/core/api/documents"));
    }

    /**
     * The whole path end to end: an exception becomes a problem body, a status, and a content type
     * a client can recognise. {@code application/problem+json} is the part that makes RFC 9457
     * usable — without it a caller sees JSON and has to guess at its shape.
     */
    @Test
    void anExceptionBecomesAProblemJsonResponseCarryingTheMappedStatus() {
        ResponseEntity<Object> response = translator.handleAnyException(new IllegalStateException("gave way"), anyRequest()).block();

        assertThat(response).isNotNull();
        assertThat(response.getStatusCode().value()).isEqualTo(HttpStatus.INTERNAL_SERVER_ERROR.value());
        assertThat(response.getHeaders().getContentType()).isEqualTo(MediaType.APPLICATION_PROBLEM_JSON);
        assertThat(response.getBody()).isInstanceOf(ProblemDetailWithCause.class);
    }

    /**
     * A {@link BadRequestAlertException} additionally carries the alert headers the frontend reads
     * to show a message against the right entity.
     *
     * <p>Note what this documents rather than endorses: on this path the headers are non-null, so
     * the content type is left as the caller's rather than set to {@code application/problem+json} —
     * the body is a problem and does not say so. That is current behaviour, and if it is ever fixed
     * this assertion is where it will surface instead of the change going unnoticed.
     */
    @Test
    void aBadRequestAlertCarriesItsAlertHeaders() {
        ResponseEntity<Object> response = translator
            .handleAnyException(new BadRequestAlertException("Name already used", "user", "nameexists"), anyRequest())
            .block();

        assertThat(response).isNotNull();
        Map<String, List<String>> headers = response.getHeaders().asMultiValueMap();
        assertThat(headers).isNotEmpty();
        assertThat(headers.values()).anySatisfy(values -> assertThat(values).contains("user"));
        assertThat(response.getHeaders().getContentType()).isNull();
    }

    /**
     * Once the response has started being written there is no status left to change, so the original
     * exception is propagated rather than an {@code UnsupportedOperationException} from trying to set
     * one. The replacement would be a second failure hiding the first, which is the harder of the two
     * to debug because it names the wrong thing.
     */
    @Test
    void anAlreadyCommittedResponseRethrowsTheOriginalFailureInsteadOfRewritingIt() {
        MockServerWebExchange exchange = anyRequest();
        exchange.getResponse().setComplete().block();

        IllegalStateException original = new IllegalStateException("gave way");

        assertThatThrownBy(() -> translator.handleAnyException(original, exchange).block()).isSameAs(original);
    }

    /**
     * Properties already on the problem are left alone. A handler further in sets these to say
     * something specific about its own failure, and a translator that overwrote them on the way out
     * would silently replace the precise message with a generic one.
     */
    @Test
    void propertiesAlreadySetOnTheProblemAreNotOverwritten() {
        ProblemDetailWithCause problem = ProblemDetailWithCauseBuilder.instance().withStatus(400).build();
        problem.setProperty("message", "error.somethingSpecific");
        problem.setProperty("path", URI.create("/set/by/the/handler"));
        problem.setProperty("fieldErrors", List.of());
        problem.setDetail("already explained");

        ProblemDetailWithCause customized = translator.customizeProblem(problem, new IllegalStateException("gave way"), anyRequest());

        assertThat(customized.getProperties()).containsEntry("message", "error.somethingSpecific");
        assertThat(customized.getProperties()).containsEntry("path", URI.create("/set/by/the/handler"));
        assertThat(customized.getDetail()).isEqualTo("already explained");
    }

    /**
     * With no exchange to read a path from, the problem says {@code about:blank} rather than failing.
     * The translator runs while something has already gone wrong, so a null-pointer here would
     * replace a reportable error with an unreportable one.
     */
    @Test
    void aMissingExchangeYieldsABlankPathRatherThanAFailure() {
        ProblemDetailWithCause problem = translator.customizeProblem(
            ProblemDetailWithCauseBuilder.instance().withStatus(500).build(),
            new IllegalStateException("gave way"),
            null
        );

        assertThat(problem.getProperties()).containsEntry("path", URI.create("about:blank"));
    }

    /**
     * The causal chain is switched off, so no cause is attached. Pinned because the switch is a
     * constant with no test around it: turning it on would put every wrapped exception's message
     * into the response body, which outside development is an internals leak rather than a feature.
     */
    @Test
    void theCausalChainIsNotAttachedWhileItIsDisabled() {
        ServerWebExchange request = anyRequest();

        assertThat(translator.buildCause(new IllegalStateException("inner"), request)).isEmpty();
        assertThat(translator.buildCause(null, request)).isEmpty();
        assertThat(
            translator.wrapAndCustomizeProblem(new RuntimeException("outer", new IllegalStateException("inner")), request).getCause()
        ).isNull();
    }
}
