package com.xenopsoftware.gateway.web.rest.errors;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import jakarta.validation.ConstraintViolationException;
import java.lang.reflect.Method;
import java.util.Set;
import org.junit.jupiter.api.Test;
import org.springframework.core.MethodParameter;
import org.springframework.core.env.Environment;
import org.springframework.http.HttpStatus;
import org.springframework.mock.http.server.reactive.MockServerHttpRequest;
import org.springframework.mock.web.server.MockServerWebExchange;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.authentication.BadCredentialsException;
import org.springframework.security.core.userdetails.UsernameNotFoundException;
import org.springframework.validation.BeanPropertyBindingResult;
import org.springframework.validation.FieldError;
import org.springframework.web.ErrorResponseException;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.support.WebExchangeBindException;
import org.springframework.web.server.ResponseStatusException;
import org.springframework.web.server.ServerWebExchange;
import tech.jhipster.web.rest.errors.ProblemDetailWithCause;
import tech.jhipster.web.rest.errors.ProblemDetailWithCause.ProblemDetailWithCauseBuilder;

/**
 * The exception-to-status mapping table in {@link ExceptionTranslator}.
 *
 * <p>{@link ExceptionTranslatorUnitTest} covers what the translator is allowed to say; this covers
 * what code it says it with. The distinction matters because clients branch on the status, not the
 * text: a browser retries a 401 by re-authenticating and gives up on a 403, and monitoring counts
 * 5xx as our fault and 4xx as the caller's. An authorization failure mapped to 500 is a page at
 * three in the morning for a request that was correctly refused.
 *
 * <p>The security mappings are the load-bearing ones. Bad credentials and an unknown username must
 * both answer 401 and answer it identically — if one of them ever became a 404, the difference
 * would turn the login endpoint into an oracle for which accounts exist.
 */
class ExceptionTranslatorMappingUnitTest {

    private final ExceptionTranslator translator = translatorFor("dev");

    private static ExceptionTranslator translatorFor(String... activeProfiles) {
        Environment env = mock(Environment.class);
        when(env.getActiveProfiles()).thenReturn(activeProfiles);
        return new ExceptionTranslator(env);
    }

    private static ServerWebExchange anyRequest() {
        return MockServerWebExchange.from(MockServerHttpRequest.get("/services/core/api/documents"));
    }

    private ProblemDetailWithCause problemFor(Throwable error) {
        return translator.wrapAndCustomizeProblem(error, anyRequest());
    }

    /** A method used only as a source of a {@link MethodParameter} for binding failures. */
    @SuppressWarnings("unused")
    private static void bindingTarget(String body) {}

    private static WebExchangeBindException bindingFailure(FieldError... fieldErrors) throws NoSuchMethodException {
        Method method = ExceptionTranslatorMappingUnitTest.class.getDeclaredMethod("bindingTarget", String.class);
        BeanPropertyBindingResult binding = new BeanPropertyBindingResult(new Object(), "userDTO");
        for (FieldError fieldError : fieldErrors) {
            binding.addError(fieldError);
        }
        return new WebExchangeBindException(new MethodParameter(method, 0), binding);
    }

    @ResponseStatus(value = HttpStatus.CONFLICT, reason = "That name is taken")
    private static class AnnotatedConflictException extends RuntimeException {

        AnnotatedConflictException() {
            super("conflict");
        }
    }

    /**
     * Refused, not unauthenticated. Sending 401 here would tell a browser to prompt for credentials
     * the user already has, which loops rather than reporting the refusal.
     */
    @Test
    void anAuthorizationFailureIsForbidden() {
        assertThat(problemFor(new AccessDeniedException("no")).getStatus()).isEqualTo(HttpStatus.FORBIDDEN.value());
    }

    /**
     * Both authentication failures answer 401, and they answer it the same way. Asserted together
     * rather than in two tests because it is the sameness that matters: a change that split them
     * would pass two separate tests and still leak which accounts exist.
     */
    @Test
    void bothAuthenticationFailuresAreUnauthorizedAndIndistinguishable() {
        ProblemDetailWithCause wrongPassword = problemFor(new BadCredentialsException("bad"));
        ProblemDetailWithCause noSuchUser = problemFor(new UsernameNotFoundException("nobody"));

        assertThat(wrongPassword.getStatus()).isEqualTo(HttpStatus.UNAUTHORIZED.value());
        assertThat(noSuchUser.getStatus()).isEqualTo(wrongPassword.getStatus());
        assertThat(noSuchUser.getTitle()).isEqualTo(wrongPassword.getTitle());
        assertThat(noSuchUser.getType()).isEqualTo(wrongPassword.getType());
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
     * Anything unrecognised is a 500 with the generic type. This is the branch every new exception
     * lands in until someone maps it, so it has to be a safe default rather than an accident.
     */
    @Test
    void anUnmappedExceptionIsAnInternalErrorWithTheDefaultType() {
        ProblemDetailWithCause problem = problemFor(new IllegalStateException("something gave way"));

        assertThat(problem.getStatus()).isEqualTo(HttpStatus.INTERNAL_SERVER_ERROR.value());
        assertThat(problem.getType()).isEqualTo(ErrorConstants.DEFAULT_TYPE);
        assertThat(problem.getProperties()).containsEntry("message", "error.http.500");
    }

    /** An exception that declares its own status through the annotation keeps it, reason and all. */
    @Test
    void anAnnotatedExceptionKeepsItsDeclaredStatusAndReason() {
        ProblemDetailWithCause problem = problemFor(new AnnotatedConflictException());

        assertThat(problem.getStatus()).isEqualTo(HttpStatus.CONFLICT.value());
        assertThat(problem.getTitle()).isEqualTo("That name is taken");
    }

    /**
     * The annotation is looked for down the cause chain, not just on the thrown class. Without this
     * every wrapped exception — which in practice is most of them, once a framework has touched it —
     * would collapse to 500 and lose a status somebody deliberately declared.
     */
    @Test
    void anAnnotatedCauseStillDeterminesTheStatus() {
        ProblemDetailWithCause problem = problemFor(new RuntimeException("wrapper", new AnnotatedConflictException()));

        assertThat(problem.getStatus()).isEqualTo(HttpStatus.CONFLICT.value());
    }

    /** Spring's own errors already carry a status; it is taken rather than re-derived. */
    @Test
    void anErrorResponseContributesItsOwnStatus() {
        assertThat(problemFor(new ResponseStatusException(HttpStatus.NOT_FOUND, "nope")).getStatus()).isEqualTo(
            HttpStatus.NOT_FOUND.value()
        );
    }

    /**
     * A problem body that already went through this translator further in is reused rather than
     * rebuilt, so a detail set deliberately downstream is not overwritten on the way out.
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
     * A binding failure reports which fields were rejected and why. The object name loses its
     * {@code DTO} suffix because the response is a public contract and the suffix is an internal
     * naming convention — it names our class layout to whoever sent the bad request.
     */
    @Test
    void aBindingFailureReportsItsFieldErrorsWithTheDtoSuffixStripped() throws NoSuchMethodException {
        WebExchangeBindException error = bindingFailure(
            new FieldError("userDTO", "login", null, false, new String[] { "NotNull" }, null, "must not be null")
        );

        ProblemDetailWithCause problem = problemFor(error);

        assertThat(problem.getProperties()).containsEntry("message", ErrorConstants.ERR_VALIDATION);
        assertThat(problem.getProperties())
            .extractingByKey("fieldErrors")
            .asInstanceOf(org.assertj.core.api.InstanceOfAssertFactories.list(FieldErrorVM.class))
            .singleElement()
            .satisfies(fieldError -> {
                assertThat(fieldError.getObjectName()).isEqualTo("user");
                assertThat(fieldError.getField()).isEqualTo("login");
                assertThat(fieldError.getMessage()).isEqualTo("must not be null");
            });
    }

    /**
     * With no message to show, the validation code is reported instead of an empty string. An error
     * body that says a field is wrong without saying anything about why is worse than useless to the
     * caller: it is actionable-looking and unactionable.
     */
    @Test
    void aFieldErrorWithoutAMessageFallsBackToItsCode() throws NoSuchMethodException {
        WebExchangeBindException error = bindingFailure(
            new FieldError("userDTO", "email", null, false, new String[] { "Email" }, null, "  ")
        );

        ProblemDetailWithCause problem = problemFor(error);

        assertThat(problem.getProperties())
            .extractingByKey("fieldErrors")
            .asInstanceOf(org.assertj.core.api.InstanceOfAssertFactories.list(FieldErrorVM.class))
            .singleElement()
            .satisfies(fieldError -> assertThat(fieldError.getMessage()).isEqualTo("Email"));
    }

    /** Every problem carries the path it came from, so an error in a log can be tied to a route. */
    @Test
    void theRequestPathIsAlwaysReported() {
        assertThat(problemFor(new IllegalStateException("x")).getProperties()).containsEntry(
            "path",
            java.net.URI.create("/services/core/api/documents")
        );
    }
}
