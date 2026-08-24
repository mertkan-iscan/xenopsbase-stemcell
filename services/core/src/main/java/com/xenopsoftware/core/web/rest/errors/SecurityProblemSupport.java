package com.xenopsoftware.core.web.rest.errors;

import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.util.LinkedHashMap;
import java.util.Map;
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
 * <h2>Why the body is serialised with Jackson</h2>
 *
 * <p>It used to be assembled by string formatting, on the reasoning that reaching for the
 * {@code ObjectMapper} would "add a dependency on the very layer that is not running yet". That
 * conflated two different things: the layer that is not running is {@code @RestControllerAdvice},
 * and {@code ObjectMapper} is not part of it. It is an ordinary bean, usable from a servlet filter
 * like any other.
 *
 * <p>The cost of the conflation was a hand-rolled escaper for the one attacker-controlled field,
 * which handled backslash, quote, LF and CR and nothing else — leaving every other control
 * character to land unescaped inside a JSON string literal, where it is illegal. Serialising the
 * document removes the whole class of defect rather than adding the next missing character to a
 * list (T-5.12, #232).
 */
@Component
public class SecurityProblemSupport implements AuthenticationEntryPoint, AccessDeniedHandler {

    private final ObjectMapper objectMapper;

    public SecurityProblemSupport(ObjectMapper objectMapper) {
        this.objectMapper = objectMapper;
    }

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

    private void write(HttpServletResponse response, HttpStatus status, String title, String detail, HttpServletRequest request)
        throws IOException {
        response.setStatus(status.value());
        response.setContentType(MediaType.APPLICATION_PROBLEM_JSON_VALUE);

        // LinkedHashMap, not Map.of: RFC 9457 does not require an order, but a stable one keeps
        // the golden-file assertions in the API tests from failing on a rehash.
        Map<String, Object> problem = new LinkedHashMap<>();
        problem.put("type", "about:blank");
        problem.put("title", title);
        problem.put("status", status.value());
        problem.put("detail", detail);
        problem.put("instance", request.getRequestURI() == null ? "" : request.getRequestURI());

        objectMapper.writeValue(response.getWriter(), problem);
    }
}
