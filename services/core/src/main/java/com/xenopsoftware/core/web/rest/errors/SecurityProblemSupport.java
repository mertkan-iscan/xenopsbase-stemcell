package com.xenopsoftware.core.web.rest.errors;

import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.core.AuthenticationException;
import org.springframework.security.web.AuthenticationEntryPoint;
import org.springframework.security.web.access.AccessDeniedHandler;
import org.springframework.stereotype.Component;

/**
 * Gives Spring Security's 401 and 403 an RFC 9457 body (T-3.8).
 *
 * <h2>Why the ExceptionTranslator does not cover these</h2>
 *
 * {@code ExceptionTranslator} is a {@code @RestControllerAdvice}, and advice only sees exceptions
 * raised by a controller. Security runs as a servlet filter, <b>before any controller exists</b>,
 * so an authentication or authorisation failure never reaches it. The default handlers write an
 * empty body with only a status line.
 *
 * <p>That is a real inconsistency rather than a cosmetic one: a client parsing errors gets a
 * problem document for every failure except the two most common ones, and has to special-case
 * "empty body" for exactly the cases where knowing why would help most.
 *
 * <p>The body is written by hand for the same reason — there is no advice in scope to serialise
 * one, and reaching for the {@code ObjectMapper} here would add a dependency on the very layer
 * that is not running yet.
 */
@Component
public class SecurityProblemSupport implements AuthenticationEntryPoint, AccessDeniedHandler {

    @Override
    public void commence(HttpServletRequest request, HttpServletResponse response, AuthenticationException e) throws IOException {
        // WWW-Authenticate is what makes this a well-formed 401 under RFC 9110. Spring's default
        // entry point sets it; a replacement that forgets it turns a correct 401 into an
        // ambiguous one.
        response.setHeader("WWW-Authenticate", "Bearer realm=\"api\"");
        write(
            response,
            HttpStatus.UNAUTHORIZED,
            "Unauthorized",
            "Authentication is required. Present a bearer token issued by the configured identity provider.",
            request
        );
    }

    @Override
    public void handle(HttpServletRequest request, HttpServletResponse response, AccessDeniedException e) throws IOException {
        // Deliberately says nothing about WHICH authority was missing. Naming it tells an
        // unauthorised caller the shape of the permission model, which is free reconnaissance.
        write(response, HttpStatus.FORBIDDEN, "Forbidden", "Authenticated, but not permitted to perform this operation.", request);
    }

    private static void write(HttpServletResponse response, HttpStatus status, String title, String detail, HttpServletRequest request)
        throws IOException {
        response.setStatus(status.value());
        response.setContentType(MediaType.APPLICATION_PROBLEM_JSON_VALUE);
        response
            .getWriter()
            .write(
                """
                {"type":"about:blank","title":"%s","status":%d,"detail":"%s","instance":"%s"}""".formatted(
                        title,
                        status.value(),
                        detail,
                        escape(request.getRequestURI())
                    )
            );
    }

    /** The path is attacker-controlled and lands inside a JSON string literal. */
    private static String escape(String value) {
        return value == null ? "" : value.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "").replace("\r", "");
    }
}
