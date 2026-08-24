package com.xenopsoftware.core.web.rest.errors;

import static org.assertj.core.api.Assertions.assertThat;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.authentication.BadCredentialsException;

/**
 * The 401 and 403 bodies are well-formed for every request path (T-5.12, #232).
 *
 * WHY THIS EXISTS
 *
 * The body used to be assembled by string formatting, with a hand-rolled escaper for the one
 * attacker-controlled field. It escaped backslash, quote, LF and CR — and nothing else. Every
 * other control character is illegal unescaped inside a JSON string literal, so a request path
 * containing one produced a response that no client could parse, from the error handler whose
 * entire job is to be parseable.
 *
 * These tests assert the property rather than the implementation: whatever is in the path, the
 * body parses and `instance` round-trips. They would fail against the old escaper and keep passing
 * if the serialiser is swapped again.
 */
class SecurityProblemSupportTest {

    private final ObjectMapper objectMapper = new ObjectMapper();
    private final SecurityProblemSupport support = new SecurityProblemSupport(objectMapper);

    private JsonNode bodyFor403(String requestUri) throws Exception {
        MockHttpServletRequest request = new MockHttpServletRequest();
        request.setRequestURI(requestUri);
        MockHttpServletResponse response = new MockHttpServletResponse();

        support.handle(request, response, new AccessDeniedException("denied"));

        return objectMapper.readTree(response.getContentAsString());
    }

    @Test
    @DisplayName("an ordinary path produces a well-formed problem document")
    void ordinaryPath() throws Exception {
        JsonNode body = bodyFor403("/api/documents/42");

        assertThat(body.get("type").asText()).isEqualTo("about:blank");
        assertThat(body.get("title").asText()).isEqualTo("Forbidden");
        assertThat(body.get("status").asInt()).isEqualTo(403);
        assertThat(body.get("instance").asText()).isEqualTo("/api/documents/42");
    }

    @Test
    @DisplayName("a control character in the path still yields parseable JSON")
    void controlCharacterInPath() throws Exception {
        // The old escaper stripped \n and \r and passed everything else through, so a tab landed
        // raw inside a JSON string literal and the document became unparseable. This is the case
        // that motivated the change.
        String uri = "/api/documents/	tab";

        JsonNode body = bodyFor403(uri);

        assertThat(body.get("instance").asText()).isEqualTo(uri);
        assertThat(body.get("status").asInt()).isEqualTo(403);
    }

    @Test
    @DisplayName("quotes and backslashes in the path cannot break out of the JSON string")
    void quotesAndBackslashes() throws Exception {
        String uri = "/api/\"quoted\"/back\slash";

        JsonNode body = bodyFor403(uri);

        assertThat(body.get("instance").asText()).isEqualTo(uri);
        assertThat(body.get("title").asText()).isEqualTo("Forbidden");
    }

    @Test
    @DisplayName("a 401 carries WWW-Authenticate and a well-formed body")
    void unauthorizedCarriesChallenge() throws Exception {
        MockHttpServletRequest request = new MockHttpServletRequest();
        request.setRequestURI("/api/documents");
        MockHttpServletResponse response = new MockHttpServletResponse();

        support.commence(request, response, new BadCredentialsException("nope"));

        // Dropping this header turns a correct 401 into an ambiguous one, and nothing else
        // asserts it.
        assertThat(response.getHeader("WWW-Authenticate")).isEqualTo("Bearer realm=\"api\"");

        JsonNode body = objectMapper.readTree(response.getContentAsString());
        assertThat(body.get("status").asInt()).isEqualTo(401);
        assertThat(body.get("title").asText()).isEqualTo("Unauthorized");
    }

    @Test
    @DisplayName("the 403 body names no authority")
    void forbiddenLeaksNoPermissionShape() throws Exception {
        JsonNode body = bodyFor403("/api/admin/things");

        // Naming the missing authority is free reconnaissance for an unauthorised caller. The
        // handler comment says so; nothing asserted it until now.
        assertThat(body.get("detail").asText()).doesNotContainIgnoringCase("role").doesNotContainIgnoringCase("authority");
    }
}
