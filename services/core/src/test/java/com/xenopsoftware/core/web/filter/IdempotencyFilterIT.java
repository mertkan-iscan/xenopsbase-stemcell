package com.xenopsoftware.core.web.filter;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.xenopsoftware.core.IntegrationTest;
import com.xenopsoftware.core.config.ObjectStorageTestcontainer;
import com.xenopsoftware.core.repository.DocumentRepository;
import com.xenopsoftware.core.repository.IdempotencyRecordRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.MediaType;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.MvcResult;

/**
 * Idempotency keys against a real database (T-3.8).
 *
 * <p>Uses the document endpoints as the subject because they are the only unsafe endpoints that
 * exist, and because a real one exercises the parts a synthetic controller would not: a JSON body
 * to hash, a 201 to store, and a downstream handler that must still receive its body after the
 * filter has consumed it.
 */
@IntegrationTest
@org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc
class IdempotencyFilterIT {

    private static final String USER = "33333333-3333-3333-3333-333333333333";
    private static final String OTHER = "44444444-4444-4444-4444-444444444444";

    @DynamicPropertySource
    static void objectStorage(DynamicPropertyRegistry registry) {
        ObjectStorageTestcontainer.registerTo(registry);
    }

    @Autowired
    private MockMvc mockMvc;

    @Autowired
    private IdempotencyRecordRepository idempotencyRepository;

    @Autowired
    private DocumentRepository documentRepository;

    @Autowired
    private ObjectMapper objectMapper;

    @BeforeEach
    void clean() {
        idempotencyRepository.deleteAll();
        documentRepository.deleteAll();
    }

    private static SecurityMockMvcRequestPostProcessors.JwtRequestPostProcessor asUser(String sub) {
        return SecurityMockMvcRequestPostProcessors.jwt()
            .jwt(builder -> builder.subject(sub))
            .authorities(new SimpleGrantedAuthority("app-user"));
    }

    private MvcResult createDocument(String sub, String key, String filename) throws Exception {
        var request = post("/api/documents")
            .with(asUser(sub))
            .contentType(MediaType.APPLICATION_JSON)
            .content("{\"filename\":\"" + filename + "\",\"contentType\":\"text/plain\",\"sizeBytes\":10}");
        if (key != null) {
            request = request.header(IdempotencyFilter.HEADER, key);
        }
        return mockMvc.perform(request).andReturn();
    }

    @Test
    void aRetryWithTheSameKeyReplaysTheOriginalResponseAndCreatesNothingNew() throws Exception {
        MvcResult first = createDocument(USER, "key-alpha", "one.txt");
        assertThat(first.getResponse().getStatus()).isEqualTo(201);
        assertThat(first.getResponse().getHeader(IdempotencyFilter.REPLAYED_HEADER)).isNull();

        MvcResult retry = createDocument(USER, "key-alpha", "one.txt");

        assertThat(retry.getResponse().getStatus()).as("the stored status, not a fresh one").isEqualTo(201);
        assertThat(retry.getResponse().getHeader(IdempotencyFilter.REPLAYED_HEADER)).isEqualTo("true");

        JsonNode firstBody = objectMapper.readTree(first.getResponse().getContentAsString());
        JsonNode retryBody = objectMapper.readTree(retry.getResponse().getContentAsString());
        assertThat(retryBody.get("id").asLong())
            .as("the retry must learn the id created the FIRST time, not a new one")
            .isEqualTo(firstBody.get("id").asLong());

        assertThat(documentRepository.findAll()).as("the work happened exactly once").hasSize(1);
    }

    @Test
    void theSameKeyOnADifferentRequestIsRejectedRatherThanQuietlyReplayed() throws Exception {
        createDocument(USER, "key-beta", "one.txt");

        MvcResult reused = createDocument(USER, "key-beta", "COMPLETELY-DIFFERENT.txt");

        assertThat(reused.getResponse().getStatus()).isEqualTo(422);
        assertThat(reused.getResponse().getContentType()).startsWith(MediaType.APPLICATION_PROBLEM_JSON_VALUE);
        assertThat(documentRepository.findAll()).as("the second request was not performed").hasSize(1);
    }

    @Test
    void keysAreScopedToTheCallerSoOneUserCannotReadAnothersResponse() throws Exception {
        MvcResult mine = createDocument(USER, "shared-key", "mine.txt");
        MvcResult theirs = createDocument(OTHER, "shared-key", "theirs.txt");

        assertThat(theirs.getResponse().getStatus()).as("not a 409 or a replay — an unrelated request").isEqualTo(201);
        assertThat(theirs.getResponse().getHeader(IdempotencyFilter.REPLAYED_HEADER)).isNull();

        JsonNode mineBody = objectMapper.readTree(mine.getResponse().getContentAsString());
        JsonNode theirsBody = objectMapper.readTree(theirs.getResponse().getContentAsString());
        assertThat(theirsBody.get("id").asLong()).isNotEqualTo(mineBody.get("id").asLong());

        assertThat(documentRepository.findAll()).hasSize(2);
    }

    @Test
    void withoutAKeyNothingIsRecordedAndEveryRequestActs() throws Exception {
        createDocument(USER, null, "a.txt");
        createDocument(USER, null, "a.txt");

        assertThat(idempotencyRepository.findAll()).as("opt-in: no key, no record").isEmpty();
        assertThat(documentRepository.findAll()).as("both requests acted").hasSize(2);
    }

    @Test
    void theDownstreamHandlerStillReceivesTheBodyTheFilterAlreadyRead() throws Exception {
        // Regression guard. Hashing the body consumes the request stream, so without a wrapper
        // that can serve it again the controller sees an empty body and fails validation — a
        // failure that points nowhere near this filter.
        MvcResult result = createDocument(USER, "key-body", "readable.txt");

        assertThat(result.getResponse().getStatus()).isEqualTo(201);
        assertThat(documentRepository.findAll()).singleElement().satisfies(d -> assertThat(d.getFilename()).isEqualTo("readable.txt"));
    }

    @Test
    void aFailedRequestDoesNotLeaveAClaimThatBlocksEveryLaterRetry() throws Exception {
        // sizeBytes over the configured maximum is rejected with 413 by DocumentResource.
        var oversized = post("/api/documents")
            .with(asUser(USER))
            .header(IdempotencyFilter.HEADER, "key-fail")
            .contentType(MediaType.APPLICATION_JSON)
            .content("{\"filename\":\"huge.bin\",\"contentType\":\"application/octet-stream\",\"sizeBytes\":52428801}");
        mockMvc.perform(oversized).andExpect(status().isPayloadTooLarge());

        assertThat(idempotencyRepository.findAll())
            .as("an unsuccessful outcome must not be stored, or the failure becomes permanent")
            .isEmpty();

        // The same key must still work once the client sends something valid.
        MvcResult retry = createDocument(USER, "key-fail", "now-valid.txt");
        assertThat(retry.getResponse().getStatus()).isEqualTo(201);
    }
}
