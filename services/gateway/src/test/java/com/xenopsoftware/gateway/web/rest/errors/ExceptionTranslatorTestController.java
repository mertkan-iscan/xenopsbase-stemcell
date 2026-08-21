package com.xenopsoftware.gateway.web.rest.errors;

import io.swagger.v3.oas.annotations.Hidden;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotNull;
import org.springframework.http.HttpStatus;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.authentication.BadCredentialsException;
import org.springframework.web.bind.annotation.*;

/**
 * Hidden from the OpenAPI document.
 *
 * <p>This controller exists only in the test source set, but the spec is captured from a running
 * test context (see OpenApiSpecIT) -- so without this it appears in the published contract, and a
 * generated client gets typed methods for endpoints that do not exist in any deployment.
 *
 * <p>{@code @Hidden} rather than a path exclusion in springdoc configuration: the production config
 * should not have to know the names of test fixtures, and a list of excluded paths is one more
 * thing to keep in step with the tests.
 */
@Hidden
@RestController
@RequestMapping("/api/exception-translator-test")
public class ExceptionTranslatorTestController {


    @PostMapping("/method-argument")
    public void methodArgument(@Valid @RequestBody TestDTO testDTO) {
        // empty method
    }

    @GetMapping("/missing-servlet-request-part")
    public void missingServletRequestPartException(@RequestPart("part") String part) {
        // empty method
    }

    @GetMapping("/missing-servlet-request-parameter")
    public void missingServletRequestParameterException(@RequestParam("param") String param) {
        // empty method
    }

    @GetMapping("/access-denied")
    public void accessdenied() {
        throw new AccessDeniedException("test access denied!");
    }

    @GetMapping("/unauthorized")
    public void unauthorized() {
        throw new BadCredentialsException("test authentication failed!");
    }

    @GetMapping("/response-status")
    public void exceptionWithResponseStatus() {
        throw new TestResponseStatusException();
    }

    @GetMapping("/internal-server-error")
    public void internalServerError() {
        throw new RuntimeException();
    }

    public static class TestDTO {

        @NotNull(message = "must not be null")
        private String test;

        public String getTest() {
            return test;
        }

        public void setTest(String test) {
            this.test = test;
        }
    }

    @ResponseStatus(value = HttpStatus.BAD_REQUEST, reason = "test response status")
    @SuppressWarnings("serial")
    public static class TestResponseStatusException extends RuntimeException {}
}
