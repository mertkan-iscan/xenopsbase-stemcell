package com.xenopsoftware.core.web.rest;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.xenopsoftware.core.IntegrationTest;
import com.xenopsoftware.core.config.ObjectStorageTestcontainer;
import com.xenopsoftware.core.domain.Document;
import com.xenopsoftware.core.repository.DocumentRepository;
import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
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
 * End-to-end document storage against a real S3 implementation (T-3.7).
 *
 * <p>The bytes in these tests genuinely do not pass through the application. Each upload is a
 * {@link HttpClient} PUT straight to MinIO using the presigned URL the API returned, and each
 * download is a GET to the presigned URL behind the redirect. That is the criterion, so testing it
 * any other way would be testing something else.
 */
@IntegrationTest
@org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc
class DocumentResourceIT {

    /**
     * Declared here rather than on the container holder. The TestContext framework applies a
     * test-class {@code @DynamicPropertySource} before the context refreshes, which is what
     * {@code StorageConfiguration}'s {@code @ConditionalOnProperty} needs in order to see the
     * bucket name at all.
     */
    @DynamicPropertySource
    static void objectStorage(DynamicPropertyRegistry registry) {
        ObjectStorageTestcontainer.registerTo(registry);
    }

    private static final String OWNER_SUB = "11111111-1111-1111-1111-111111111111";
    private static final String OTHER_SUB = "22222222-2222-2222-2222-222222222222";

    private static final HttpClient HTTP = HttpClient.newHttpClient();

    @Autowired
    private MockMvc mockMvc;

    @Autowired
    private DocumentRepository documentRepository;

    @Autowired
    private ObjectMapper objectMapper;

    @BeforeEach
    void clean() {
        documentRepository.deleteAll();
    }

    /** Authenticates as a given {@code sub}, which is what the service keys ownership on. */
    private static SecurityMockMvcRequestPostProcessors.JwtRequestPostProcessor asUser(String sub) {
        return SecurityMockMvcRequestPostProcessors.jwt()
            .jwt(builder -> builder.subject(sub).claim("preferred_username", "user-" + sub.charAt(0)))
            .authorities(new SimpleGrantedAuthority("app-user"));
    }

    private JsonNode initiate(String sub, String filename, String contentType, long sizeBytes) throws Exception {
        MvcResult result = mockMvc
            .perform(
                post("/api/documents")
                    .with(asUser(sub))
                    .contentType(MediaType.APPLICATION_JSON)
                    .content("{\"filename\":\"" + filename + "\",\"contentType\":\"" + contentType + "\",\"sizeBytes\":" + sizeBytes + "}")
            )
            .andExpect(status().isCreated())
            .andReturn();
        return objectMapper.readTree(result.getResponse().getContentAsString());
    }

    private static int putBytes(String presignedUrl, String contentType, byte[] body) throws IOException, InterruptedException {
        HttpRequest request = HttpRequest.newBuilder(URI.create(presignedUrl))
            .header("Content-Type", contentType)
            .PUT(HttpRequest.BodyPublishers.ofByteArray(body))
            .build();
        return HTTP.send(request, HttpResponse.BodyHandlers.discarding()).statusCode();
    }

    @Test
    void uploadsAndDownloadsWithoutTheBytesPassingThroughTheService() throws Exception {
        byte[] content = "the quick brown fox".getBytes(StandardCharsets.UTF_8);

        JsonNode ticket = initiate(OWNER_SUB, "notes.txt", "text/plain", content.length);
        long id = ticket.get("id").asLong();

        assertThat(ticket.get("uploadUrl").asText())
            .as("a presigned URL points at the object store, not back at this service")
            .contains("X-Amz-Signature");

        assertThat(putBytes(ticket.get("uploadUrl").asText(), "text/plain", content))
            .as("the object store accepted the presigned PUT")
            .isEqualTo(200);

        // Not downloadable until completion, because nothing has verified any bytes exist.
        mockMvc.perform(get("/api/documents/{id}/download", id).with(asUser(OWNER_SUB))).andExpect(status().isNotFound());

        mockMvc
            .perform(post("/api/documents/{id}/complete", id).with(asUser(OWNER_SUB)))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.status").value("AVAILABLE"))
            // The size comes from the store, not from anything the client sent.
            .andExpect(jsonPath("$.sizeBytes").value(content.length));

        MvcResult redirect = mockMvc
            .perform(get("/api/documents/{id}/download", id).with(asUser(OWNER_SUB)))
            .andExpect(status().isFound())
            .andExpect(header().string("Cache-Control", "no-store"))
            .andReturn();

        String downloadUrl = redirect.getResponse().getHeader("Location");
        assertThat(downloadUrl).contains("X-Amz-Signature");

        HttpResponse<byte[]> fetched = HTTP.send(
            HttpRequest.newBuilder(URI.create(downloadUrl)).GET().build(),
            HttpResponse.BodyHandlers.ofByteArray()
        );

        assertThat(fetched.statusCode()).isEqualTo(200);
        assertThat(fetched.body()).isEqualTo(content);
        assertThat(fetched.headers().firstValue("content-disposition"))
            .as("the stored key carries no filename; it is applied per request")
            .hasValueSatisfying(v -> assertThat(v).contains("notes.txt"));
    }

    @Test
    void completionIsRefusedWhenTheObjectWasNeverUploaded() throws Exception {
        JsonNode ticket = initiate(OWNER_SUB, "ghost.txt", "text/plain", 5);

        // The client claims success without ever having uploaded. The service checks the store.
        mockMvc
            .perform(post("/api/documents/{id}/complete", ticket.get("id").asLong()).with(asUser(OWNER_SUB)))
            .andExpect(status().isNotFound());

        assertThat(documentRepository.findAll())
            .singleElement()
            .satisfies(d -> assertThat(d.getStatus()).isEqualTo(Document.Status.PENDING));
    }

    @Test
    void completionIsIdempotent() throws Exception {
        JsonNode ticket = initiate(OWNER_SUB, "twice.txt", "text/plain", 1);
        long id = ticket.get("id").asLong();
        putBytes(ticket.get("uploadUrl").asText(), "text/plain", "x".getBytes(StandardCharsets.UTF_8));

        mockMvc.perform(post("/api/documents/{id}/complete", id).with(asUser(OWNER_SUB))).andExpect(status().isOk());
        // A client that retries after a lost response must not be punished for succeeding twice.
        mockMvc
            .perform(post("/api/documents/{id}/complete", id).with(asUser(OWNER_SUB)))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.status").value("AVAILABLE"));
    }

    @Test
    void aDocumentBelongingToSomeoneElseIsIndistinguishableFromOneThatDoesNotExist() throws Exception {
        JsonNode ticket = initiate(OWNER_SUB, "private.txt", "text/plain", "secret".getBytes(StandardCharsets.UTF_8).length);
        long id = ticket.get("id").asLong();
        putBytes(ticket.get("uploadUrl").asText(), "text/plain", "secret".getBytes(StandardCharsets.UTF_8));
        mockMvc.perform(post("/api/documents/{id}/complete", id).with(asUser(OWNER_SUB))).andExpect(status().isOk());

        mockMvc.perform(get("/api/documents/{id}/download", id).with(asUser(OTHER_SUB))).andExpect(status().isNotFound());
        mockMvc.perform(delete("/api/documents/{id}", id).with(asUser(OTHER_SUB))).andExpect(status().isNotFound());
        mockMvc.perform(get("/api/documents").with(asUser(OTHER_SUB))).andExpect(jsonPath("$.length()").value(0));

        // Still there for its owner: the other user's request was refused, not destructive.
        mockMvc.perform(get("/api/documents").with(asUser(OWNER_SUB))).andExpect(jsonPath("$.length()").value(1));
    }

    @Test
    void listingShowsOnlyCompletedDocuments() throws Exception {
        initiate(OWNER_SUB, "pending.txt", "text/plain", 10);

        JsonNode done = initiate(OWNER_SUB, "done.txt", "text/plain", 1);
        putBytes(done.get("uploadUrl").asText(), "text/plain", "y".getBytes(StandardCharsets.UTF_8));
        mockMvc.perform(post("/api/documents/{id}/complete", done.get("id").asLong()).with(asUser(OWNER_SUB))).andExpect(status().isOk());

        mockMvc
            .perform(get("/api/documents").with(asUser(OWNER_SUB)))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.length()").value(1))
            .andExpect(jsonPath("$[0].filename").value("done.txt"));
    }

    @Test
    void deleteRemovesTheRowAndThenTheObject() throws Exception {
        JsonNode ticket = initiate(OWNER_SUB, "gone.txt", "text/plain", "bye".getBytes(StandardCharsets.UTF_8).length);
        long id = ticket.get("id").asLong();
        String downloadable = ticket.get("uploadUrl").asText();
        putBytes(downloadable, "text/plain", "bye".getBytes(StandardCharsets.UTF_8));
        mockMvc.perform(post("/api/documents/{id}/complete", id).with(asUser(OWNER_SUB))).andExpect(status().isOk());

        mockMvc.perform(delete("/api/documents/{id}", id).with(asUser(OWNER_SUB))).andExpect(status().isNoContent());

        assertThat(documentRepository.findById(id)).isEmpty();
        mockMvc.perform(get("/api/documents/{id}/download", id).with(asUser(OWNER_SUB))).andExpect(status().isNotFound());
    }

    @Test
    void anUploadLargerThanTheLimitIsRefusedBeforeAnythingIsSigned() throws Exception {
        mockMvc
            .perform(
                post("/api/documents")
                    .with(asUser(OWNER_SUB))
                    .contentType(MediaType.APPLICATION_JSON)
                    .content("{\"filename\":\"huge.bin\",\"contentType\":\"application/octet-stream\",\"sizeBytes\":52428801}")
            )
            .andExpect(status().isPayloadTooLarge());

        assertThat(documentRepository.findAll()).as("nothing is recorded for an upload that was never permitted").isEmpty();
    }

    @Test
    void anUploadThatDisagreesWithItsDeclaredSizeIsRefusedByTheObjectStore() throws Exception {
        // The declared size is what gets signed, so the store -- not this service -- enforces it.
        JsonNode ticket = initiate(OWNER_SUB, "liar.txt", "text/plain", 4);

        assertThat(putBytes(ticket.get("uploadUrl").asText(), "text/plain", "far more than four bytes".getBytes(StandardCharsets.UTF_8)))
            .as("a body of the wrong length fails the signature check")
            .isEqualTo(403);
    }

    @Test
    void anonymousCallersAreRejected() throws Exception {
        mockMvc.perform(get("/api/documents")).andExpect(status().isUnauthorized());
    }
}
