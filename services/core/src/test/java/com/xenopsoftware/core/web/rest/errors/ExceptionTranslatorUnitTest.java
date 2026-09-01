package com.xenopsoftware.core.web.rest.errors;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import java.net.URI;
import org.junit.jupiter.api.Test;
import org.springframework.core.env.Environment;
import org.springframework.dao.DataAccessResourceFailureException;
import org.springframework.http.converter.HttpMessageConversionException;
import org.springframework.web.context.request.NativeWebRequest;
import tech.jhipster.web.rest.errors.ProblemDetailWithCause;
import tech.jhipster.web.rest.errors.ProblemDetailWithCause.ProblemDetailWithCauseBuilder;

/**
 * The branches of {@link ExceptionTranslator} that only exist in production.
 *
 * <p>{@link ExceptionTranslatorIT} covers the translator through a running context, and every one
 * of its nine tests runs without the {@code prod} profile. That leaves the whole of
 * {@code getCustomizedErrorDetails}' interesting half untaken — 8 of its 10 branches — because
 * those branches are the ones that exist to STOP a production deployment leaking internals into an
 * error body.
 *
 * <p>An error path that is only reachable in production and is exercised by nothing is the worst
 * combination available, and it is what T-5.9 (#172) means by preferring the branch nobody takes.
 *
 * <p>Unit rather than integration on purpose: the profile is a constructor argument away here, and
 * spinning a second context per profile to reach an if-statement would be slower and no more true.
 */
class ExceptionTranslatorUnitTest {

    private ExceptionTranslator translatorFor(String... activeProfiles) {
        Environment env = mock(Environment.class);
        when(env.getActiveProfiles()).thenReturn(activeProfiles);
        return new ExceptionTranslator(env);
    }

    private NativeWebRequest anyRequest() {
        return mock(NativeWebRequest.class);
    }

    private ProblemDetailWithCause blankProblem() {
        return ProblemDetailWithCauseBuilder.instance().withStatus(500).build();
    }

    private String detailFor(ExceptionTranslator translator, Throwable error) {
        return translator.customizeProblem(blankProblem(), error, anyRequest()).getDetail();
    }

    /**
     * Outside production the real message is wanted: a developer reading a 500 needs to know what
     * actually happened, and nobody is being handed the response.
     */
    @Test
    void outsideProductionTheRealMessageIsKept() {
        ExceptionTranslator translator = translatorFor("dev");

        assertThat(detailFor(translator, new IllegalStateException("the pool is exhausted"))).isEqualTo("the pool is exhausted");
    }

    /** In production a conversion failure must not describe the payload it failed to convert. */
    @Test
    void productionHidesMessageConversionDetail() {
        ExceptionTranslator translator = translatorFor("prod");

        assertThat(detailFor(translator, new HttpMessageConversionException("field 'ssn' cannot be deserialized"))).isEqualTo(
            "Unable to convert http message"
        );
    }

    /** In production a data access failure must not describe the schema or the query. */
    @Test
    void productionHidesDataAccessDetail() {
        ExceptionTranslator translator = translatorFor("prod");

        assertThat(detailFor(translator, new DataAccessResourceFailureException("relation \"document\" does not exist"))).isEqualTo(
            "Failure during data access"
        );
    }

    /**
     * The catch-all: any message carrying this application's package name is a stack-trace-shaped
     * leak, whatever the exception type.
     */
    @Test
    void productionHidesAnythingNamingOurOwnPackages() {
        ExceptionTranslator translator = translatorFor("prod");

        assertThat(
            detailFor(translator, new IllegalStateException("failed at com.xenopsoftware.core.service.DocumentService.load"))
        ).isEqualTo("Unexpected runtime exception");
    }

    /**
     * Production, but a message that names nothing internal. It falls through the three guards and
     * is kept — the rule is about leaking internals, not about silencing errors.
     */
    @Test
    void productionKeepsAMessageThatLeaksNothing() {
        ExceptionTranslator translator = translatorFor("prod");

        assertThat(detailFor(translator, new IllegalStateException("quota exceeded"))).isEqualTo("quota exceeded");
    }

    /** The cause's message wins over the wrapper's, which is what makes the detail useful. */
    @Test
    void theCauseMessageIsPreferredOverTheWrapper() {
        ExceptionTranslator translator = translatorFor("dev");
        Throwable wrapped = new IllegalStateException("wrapper", new IllegalArgumentException("the real reason"));

        assertThat(detailFor(translator, wrapped)).isEqualTo("the real reason");
    }

    /**
     * A problem that already carries a detail keeps it. Overwriting it would discard the more
     * specific message a handler chose in favour of a generic one derived from the exception.
     */
    @Test
    void anExistingDetailIsNotOverwritten() {
        ExceptionTranslator translator = translatorFor("dev");
        ProblemDetailWithCause problem = ProblemDetailWithCauseBuilder.instance().withStatus(400).build();
        problem.setDetail("the document is already complete");

        ProblemDetailWithCause out = translator.customizeProblem(problem, new IllegalStateException("something else"), anyRequest());

        assertThat(out.getDetail()).isEqualTo("the document is already complete");
    }

    /** about:blank is the RFC's "no type", so it is replaced rather than treated as a choice. */
    @Test
    void theBlankProblemTypeIsReplaced() {
        ExceptionTranslator translator = translatorFor("dev");
        ProblemDetailWithCause problem = ProblemDetailWithCauseBuilder.instance().withStatus(500).build();
        problem.setType(URI.create("about:blank"));

        ProblemDetailWithCause out = translator.customizeProblem(problem, new IllegalStateException("boom"), anyRequest());

        assertThat(out.getType()).isNotEqualTo(URI.create("about:blank"));
    }

    /** Every problem carries a message key, derived from the status when nothing maps one. */
    @Test
    void aMessageKeyIsAlwaysSet() {
        ExceptionTranslator translator = translatorFor("dev");

        ProblemDetailWithCause out = translator.customizeProblem(blankProblem(), new IllegalStateException("boom"), anyRequest());

        assertThat(out.getProperties()).containsKey("message");
    }
}
