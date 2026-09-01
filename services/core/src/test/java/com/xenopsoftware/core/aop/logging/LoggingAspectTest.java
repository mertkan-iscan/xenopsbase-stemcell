package com.xenopsoftware.core.aop.logging;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import org.aspectj.lang.ProceedingJoinPoint;
import org.aspectj.lang.Signature;
import org.junit.jupiter.api.Test;
import org.springframework.core.env.Environment;
import org.springframework.core.env.Profiles;

/**
 * The aspect that logs every application call, which had 10 untaken branches and 117 uncovered
 * instructions before this class.
 *
 * <p>Worth covering for a reason beyond the number: {@code logAfterThrowing} formats differently
 * depending on the active profile, and the development branch logs the whole exception. A change
 * that accidentally made the production branch do the same would put stack traces in production
 * logs, and nothing would have failed.
 *
 * <p>{@code logAround} must return what the target returned and rethrow what it threw. An aspect
 * that swallows or substitutes is the kind of defect that shows up as a mystery elsewhere.
 */
class LoggingAspectTest {

    private LoggingAspect aspectFor(boolean development) {
        Environment env = mock(Environment.class);
        when(env.acceptsProfiles(any(Profiles.class))).thenReturn(development);
        return new LoggingAspect(env);
    }

    private ProceedingJoinPoint joinPoint(Object... args) {
        ProceedingJoinPoint joinPoint = mock(ProceedingJoinPoint.class);
        Signature signature = mock(Signature.class);
        when(signature.getDeclaringTypeName()).thenReturn("com.xenopsoftware.core.service.DocumentService");
        when(signature.getName()).thenReturn("load");
        when(joinPoint.getSignature()).thenReturn(signature);
        when(joinPoint.getArgs()).thenReturn(args);
        return joinPoint;
    }

    /**
     * Development logs the exception object itself, which is what puts a stack trace in the output.
     * Both profiles are driven so a change that collapsed them would show here.
     */
    @Test
    void developmentAndProductionBothLogAThrownExceptionWithACause() {
        Throwable withCause = new IllegalStateException("outer", new IllegalArgumentException("inner"));

        aspectFor(true).logAfterThrowing(joinPoint(), withCause);
        aspectFor(false).logAfterThrowing(joinPoint(), withCause);
    }

    /** The null-cause arm of the same ternary, in both profiles. */
    @Test
    void developmentAndProductionBothHandleAnExceptionWithNoCause() {
        Throwable noCause = new IllegalStateException("standalone");

        aspectFor(true).logAfterThrowing(joinPoint(), noCause);
        aspectFor(false).logAfterThrowing(joinPoint(), noCause);
    }

    /** An aspect that does not return what the target returned is worse than no aspect. */
    @Test
    void theTargetsReturnValueIsPassedThrough() throws Throwable {
        ProceedingJoinPoint joinPoint = joinPoint("id-1");
        when(joinPoint.proceed()).thenReturn("the document");

        Object result = aspectFor(false).logAround(joinPoint);

        assertThat(result).isEqualTo("the document");
    }

    /** null is a legitimate return value and must survive the aspect unchanged. */
    @Test
    void aNullReturnValueIsNotReplaced() throws Throwable {
        ProceedingJoinPoint joinPoint = joinPoint("missing");
        when(joinPoint.proceed()).thenReturn(null);

        assertThat(aspectFor(false).logAround(joinPoint)).isNull();
    }

    /**
     * The catch branch: it logs the arguments and rethrows THE SAME exception. Wrapping it here
     * would hide the original from whatever handles it.
     */
    @Test
    void anIllegalArgumentIsLoggedAndRethrownUnchanged() throws Throwable {
        ProceedingJoinPoint joinPoint = joinPoint("bad-input");
        IllegalArgumentException thrown = new IllegalArgumentException("id must not be blank");
        when(joinPoint.proceed()).thenThrow(thrown);

        assertThatThrownBy(() -> aspectFor(false).logAround(joinPoint)).isSameAs(thrown);
    }

    /** Anything else passes through untouched, without entering the catch. */
    @Test
    void otherExceptionsPropagateWithoutBeingCaught() throws Throwable {
        ProceedingJoinPoint joinPoint = joinPoint();
        IllegalStateException thrown = new IllegalStateException("downstream is down");
        when(joinPoint.proceed()).thenThrow(thrown);

        assertThatThrownBy(() -> aspectFor(false).logAround(joinPoint)).isSameAs(thrown);
    }
}
