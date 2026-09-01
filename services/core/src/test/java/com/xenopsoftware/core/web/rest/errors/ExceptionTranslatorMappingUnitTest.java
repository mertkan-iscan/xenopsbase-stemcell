package com.xenopsoftware.core.web.rest.errors;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import jakarta.validation.ConstraintViolationException;
import java.lang.reflect.Method;
import java.net.URI;
import java.util.List;
import java.util.Map;
import java.util.Set;
import org.assertj.core.api.InstanceOfAssertFactories;
import org.junit.jupiter.api.Test;
import org.springframework.core.MethodParameter;
import org.springframework.core.env.Environment;
import org.springframework.dao.ConcurrencyFailureException;
import org.springframework.dao.OptimisticLockingFailureException;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.authentication.BadCredentialsException;
import org.springframework.validation.BeanPropertyBindingResult;
import org.springframework.validation.FieldError;
import org.springframework.web.ErrorResponseException;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.context.request.NativeWebRequest;
import org.springframework.web.context.request.ServletWebRequest;
import org.springframework.web.server.ResponseStatusException;
import tech.jhipster.web.rest.errors.ProblemDetailWithCause;
import tech.jhipster.web.rest.errors.ProblemDetailWithCause.ProblemDetailWithCauseBuilder;

/**
 * The exception-to-status mapping table in {@link ExceptionTranslator}.
 *
 * <p>{@link ExceptionTranslatorUnitTest} covers what the translator is allowed to say about a
 * failure; this covers what code it says it with. Clients branch on the status, not the text: a
 * caller retries a 409, gives up on a 403, and re-authenticates on a 401, and monitoring counts 5xx
 * as our fault and 4xx as the caller's. A conflict mapped to 500 is a page in the night for a write
 * that was correctly refused and that the caller could have retried by itself.
 *
 * <p>The concurrency mapping is the one this module leans on. Optimistic locking is how concurrent
 * writes to the same row are resolved here, so a lost race is a routine event with a correct
 * response — 409, retry — and not an error at all.
 */
class ExceptionTranslatorMappingUnitTest {

    private final ExceptionTranslator translator = translatorFor("dev");

    private static ExceptionTranslator translatorFor(String... activeProfiles) {
        Environment env = mock(Environment.class);
        when(env.getActiveProfiles()).thenReturn(activeProfiles);
        return new ExceptionTranslator(env);
    }

    private static NativeWebRequest anyRequest() {
        return new ServletWebRequest(new MockHttpServletRequest("GET", "/api/documents"));
    }

    private ProblemDetailWithCause problemFor(Throwable error) {
        return translator.wrapAndCustomizeProblem(error, anyRequest());
    }

    /** A method used only as a source of a {@link MethodParameter} for binding failures. */
    @SuppressWarnings("unused")
    private static void bindingTarget(String body) {}

    private static MethodArgumentNotValidException bindingFailure(FieldError... fieldErrors) throws NoSuchMethodException {
        Method method = ExceptionTranslatorMappingUnitTest.class.getDeclaredMethod("bindingTarget", String.class);
        BeanPropertyBindingResult binding = new BeanPropertyBindingResult(new Object(), "documentDTO");
        for (FieldError fieldError : fieldErrors) {
            binding.addError(fieldError);
        }
        return new MethodArgumentNotValidException(new MethodParameter(method, 0), binding);
    }

    @ResponseStatus(value = HttpStatus.GONE, reason = "That document was archived")
    private static class AnnotatedGoneException extends RuntimeException {

        AnnotatedGoneException() {
            super("gone");
        }
    }

    /**
     * Refused, not unauthenticated. A 401 here would tell the caller to present credentials it
     * already presented, which loops instead of reporting the refusal.
     */
    @Test
    void anAuthorizationFailureIsForbidden() {
        assertThat(problemFor(new AccessDeniedException("no")).getStatus()).isEqualTo(HttpStatus.FORBIDDEN.value());
    }

    @Test
    void badCredentialsAreUnauthorized() {
        assertThat(problemFor(new BadCredentialsException("bad")).getStatus()).isEqualTo(HttpStatus.UNAUTHORIZED.value());
    }

    /**
     * A lost optimistic-locking race is a 409 carrying the concurrency message key, because that
     * pair is what tells a client this is retryable. As a 500 it is indistinguishable from a real
     * fault: the caller stops instead of retrying, and someone gets paged for a working system.
     */
    @Test
    void aConcurrencyFailureIsAConflictTheCallerCanRetry() {
        ProblemDetailWithCause problem = problemFor(new OptimisticLockingFailureException("row moved under us"));

        assertThat(problem.getStatus()).isEqualTo(HttpStatus.CONFLICT.value());
        assertThat(problem.getProperties()).containsEntry("message", ErrorConstants.ERR_CONCURRENCY_FAILURE);
    }

    /**
     * The concurrency message key is read from the cause as well as the exception itself, which
     * matters because that is the shape it usually arrives in: the persistence layer wraps the
     * failure before it reaches here.
     *
     * <p>Note what does NOT follow the cause: the status. A wrapper is a 500 carrying the
     * concurrency key, which reads as a mixed signal. Documented rather than endorsed, so that if
     * the status ever follows the key this test is where the change is noticed.
     */
    @Test
    void aWrappedConcurrencyFailureStillCarriesTheConcurrencyKey() {
        ProblemDetailWithCause problem = problemFor(new IllegalStateException("save failed", new ConcurrencyFailureException("conflict")));

        assertThat(problem.getProperties()).containsEntry("message", ErrorConstants.ERR_CONCURRENCY_FAILURE);
        assertThat(problem.getStatus()).isEqualTo(HttpStatus.INTERNAL_SERVER_ERROR.value());
    }

    @Test
    void aConstraintViolationIsABadRequestCarryingTheValidationType() {
        ProblemDetailWithCause problem = problemFor(new ConstraintViolationException("invalid", Set.of()));

        assertThat(problem.getStatus()).isEqualTo(HttpStatus.BAD_REQUEST.value());
        assertThat(problem.getType()).isEqualTo(ErrorConstants.CONSTRAINT_VIOLATION_TYPE);
        assertThat(problem.getTitle()).isEqualTo("Method argument not valid");
        assertThat(problem.getProperties()).containsEntry("message", ErrorConstants.ERR_VALIDATION);
    }

    /**
     * Anything unrecognised is a 500 with the generic type. This is where every new exception lands
     * until somebody maps it, so it has to be a deliberate default rather than an accident.
     */
    @Test
    void anUnmappedExceptionIsAnInternalErrorWithTheDefaultType() {
        ProblemDetailWithCause problem = problemFor(new IllegalStateException("something gave way"));

        assertThat(problem.getStatus()).isEqualTo(HttpStatus.INTERNAL_SERVER_ERROR.value());
        assertThat(problem.getType()).isEqualTo(ErrorConstants.DEFAULT_TYPE);
        assertThat(problem.getProperties()).containsEntry("message", "error.http.500");
    }

    @Test
    void anAnnotatedExceptionKeepsItsDeclaredStatusAndReason() {
        ProblemDetailWithCause problem = problemFor(new AnnotatedGoneException());

        assertThat(problem.getStatus()).isEqualTo(HttpStatus.GONE.value());
        assertThat(problem.getTitle()).isEqualTo("That document was archived");
    }

    /**
     * The annotation is looked for down the cause chain, not only on the thrown class. Without it
     * every wrapped exception, which in practice is most of them once a framework has touched one,
     * would collapse to 500 and lose a status somebody declared on purpose.
     */
    @Test
    void anAnnotatedCauseStillDeterminesTheStatus() {
        assertThat(problemFor(new RuntimeException("wrapper", new AnnotatedGoneException())).getStatus()).isEqualTo(
            HttpStatus.GONE.value()
        );
    }

    /** Spring's own errors already carry a status; it is taken rather than re-derived. */
    @Test
    void anErrorResponseContributesItsOwnStatus() {
        assertThat(problemFor(new ResponseStatusException(HttpStatus.NOT_FOUND, "nope")).getStatus()).isEqualTo(
            HttpStatus.NOT_FOUND.value()
        );
    }

    /**
     * A problem body assembled further in is reused rather than rebuilt, so a detail set
     * deliberately by a handler is not replaced by a generic one on the way out.
     */
    @Test
    void anAlreadyBuiltProblemBodyIsCarriedThroughUntouched() {
        ProblemDetailWithCause existing = ProblemDetailWithCauseBuilder.instance()
            .withStatus(HttpStatus.I_AM_A_TEAPOT.value())
            .withDetail("brewing")
            .build();

        ProblemDetailWithCause problem = problemFor(new ErrorResponseException(HttpStatus.I_AM_A_TEAPOT, existing, null));

        assertThat(problem).isSameAs(existing);
        assertThat(problem.getDetail()).isEqualTo("brewing");
    }

    /**
     * A binding failure reports which fields were rejected and why, with the {@code DTO} suffix
     * stripped: the response is a public contract and the suffix is an internal naming convention,
     * so leaving it on names our class layout to whoever sent the bad request.
     */
    @Test
    void aBindingFailureReportsItsFieldErrorsWithTheDtoSuffixStripped() throws NoSuchMethodException {
        MethodArgumentNotValidException error = bindingFailure(
            new FieldError("documentDTO", "title", null, false, new String[] { "NotNull" }, null, "must not be null")
        );

        ProblemDetailWithCause problem = problemFor(error);

        assertThat(problem.getProperties()).containsEntry("message", ErrorConstants.ERR_VALIDATION);
        assertThat(problem.getProperties())
            .extractingByKey("fieldErrors")
            .asInstanceOf(InstanceOfAssertFactories.list(FieldErrorVM.class))
            .singleElement()
            .satisfies(fieldError -> {
                assertThat(fieldError.getObjectName()).isEqualTo("document");
                assertThat(fieldError.getField()).isEqualTo("title");
                assertThat(fieldError.getMessage()).isEqualTo("must not be null");
            });
    }

    /**
     * With no message to show, the validation code is reported rather than an empty string. A body
     * that says a field is wrong without saying anything about why is actionable-looking and
     * unactionable, which is worse for the caller than saying nothing.
     */
    @Test
    void aFieldErrorWithoutAMessageFallsBackToItsCode() throws NoSuchMethodException {
        MethodArgumentNotValidException error = bindingFailure(
            new FieldError("documentDTO", "owner", null, false, new String[] { "Email" }, null, "  ")
        );

        assertThat(problemFor(error).getProperties())
            .extractingByKey("fieldErrors")
            .asInstanceOf(InstanceOfAssertFactories.list(FieldErrorVM.class))
            .singleElement()
            .satisfies(fieldError -> assertThat(fieldError.getMessage()).isEqualTo("Email"));
    }

    /**
     * Properties already on the problem are left alone. A handler sets these to say something
     * specific about its own failure, and overwriting them on the way out would silently replace a
     * precise message with a generic one.
     */
    @Test
    void propertiesAlreadySetOnTheProblemAreNotOverwritten() {
        ProblemDetailWithCause problem = ProblemDetailWithCauseBuilder.instance().withStatus(400).build();
        problem.setProperty("message", "error.somethingSpecific");
        problem.setProperty("path", URI.create("/set/by/the/handler"));
        problem.setDetail("already explained");

        ProblemDetailWithCause customized = translator.customizeProblem(problem, new IllegalStateException("gave way"), anyRequest());

        assertThat(customized.getProperties()).containsEntry("message", "error.somethingSpecific");
        assertThat(customized.getProperties()).containsEntry("path", URI.create("/set/by/the/handler"));
        assertThat(customized.getDetail()).isEqualTo("already explained");
    }

    /**
     * With no request to read a path from, the problem says {@code about:blank} rather than failing.
     * The translator runs while something has already gone wrong, so a null pointer here replaces a
     * reportable error with an unreportable one.
     */
    @Test
    void aMissingRequestYieldsABlankPathRatherThanAFailure() {
        ProblemDetailWithCause problem = translator.customizeProblem(
            ProblemDetailWithCauseBuilder.instance().withStatus(500).build(),
            new IllegalStateException("gave way"),
            null
        );

        assertThat(problem.getProperties()).containsEntry("path", URI.create("about:blank"));
    }

    /** Every problem carries the path it came from, so an error in a log ties back to a route. */
    @Test
    void theRequestPathIsAlwaysReported() {
        assertThat(problemFor(new IllegalStateException("x")).getProperties()).containsEntry("path", URI.create("/api/documents"));
    }

    /**
     * The causal chain is switched off, so no cause is attached. Pinned because the switch is a
     * constant with nothing asserting on it: turning it on puts every wrapped exception's message
     * into the response body, which outside development is an internals leak and not a feature.
     */
    @Test
    void theCausalChainIsNotAttachedWhileItIsDisabled() {
        NativeWebRequest request = anyRequest();

        assertThat(translator.buildCause(new IllegalStateException("inner"), request)).isEmpty();
        assertThat(translator.buildCause(null, request)).isEmpty();
        assertThat(problemFor(new RuntimeException("outer", new IllegalStateException("inner"))).getCause()).isNull();
    }

    /**
     * The whole path end to end: an exception becomes a problem body carrying the mapped status.
     *
     * <p>The content type is deliberately NOT asserted here, and the difference from the gateway's
     * copy of this class is worth knowing. Core delegates to Spring's own
     * {@code ResponseEntityExceptionHandler}, which leaves the entity's content type unset and lets
     * {@code application/problem+json} be chosen when the body is written. The gateway's copy sets
     * it on the entity by hand. Core's is the standard path; asserting a content type here would be
     * asserting something this layer never decides.
     */
    @Test
    void anExceptionBecomesAProblemBodyCarryingTheMappedStatus() {
        ResponseEntity<Object> response = translator.handleAnyException(new IllegalStateException("gave way"), anyRequest());

        assertThat(response).isNotNull();
        assertThat(response.getStatusCode().value()).isEqualTo(HttpStatus.INTERNAL_SERVER_ERROR.value());
        assertThat(response.getBody()).isInstanceOf(ProblemDetailWithCause.class);
        assertThat(response.getBody())
            .asInstanceOf(InstanceOfAssertFactories.type(ProblemDetailWithCause.class))
            .satisfies(problem -> assertThat(problem.getProperties()).containsEntry("path", URI.create("/api/documents")));
    }

    /**
     * A {@link BadRequestAlertException} additionally carries the alert headers the frontend reads
     * to show a message against the right entity.
     *
     * <p>The alert headers survive alongside the problem body rather than replacing it, which is
     * the part worth pinning: the frontend reads the header and the caller reads the body, and a
     * change that dropped either would still look like a working 400.
     */
    @Test
    void aBadRequestAlertCarriesItsAlertHeaders() {
        ResponseEntity<Object> response = translator.handleAnyException(
            new BadRequestAlertException("Title already used", "document", "titleexists"),
            anyRequest()
        );

        Map<String, List<String>> headers = response.getHeaders().asMultiValueMap();
        assertThat(headers).isNotEmpty();
        assertThat(headers.values()).anySatisfy(values -> assertThat(values).contains("document"));
    }
}
