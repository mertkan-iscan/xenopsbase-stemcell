package com.xenopsoftware.core.repository;

import static org.assertj.core.api.Assertions.assertThat;

import com.xenopsoftware.core.config.DatabaseTestcontainer;
import com.xenopsoftware.core.domain.Document;
import com.xenopsoftware.core.tenancy.DefaultTenantResolver;
import java.util.Optional;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.data.jpa.test.autoconfigure.DataJpaTest;
import org.springframework.boot.jdbc.test.autoconfigure.AutoConfigureTestDatabase;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.boot.testcontainers.context.ImportTestcontainers;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.data.domain.AuditorAware;
import org.springframework.data.domain.PageRequest;
import org.springframework.data.jpa.repository.config.EnableJpaAuditing;

/**
 * The DATA slice: the repository against a real schema, with no web layer and no application
 * context beyond JPA (T-5.2).
 *
 * <p>The queries under test are the ownership boundary. {@code owner} holds the Keycloak
 * {@code sub}, and these derived queries are the only thing standing between one user's documents
 * and another's — {@code DocumentResource} passes {@code currentOwner()} into every one of them. A
 * mistake here is not a wrong result, it is one user reading another user's files.
 *
 * <p>{@code replace = NONE} keeps the Testcontainers Postgres rather than swapping in an embedded
 * database. The schema comes from Flyway, and validating against the real one is the point: an
 * embedded database would happily accept a mapping that Postgres rejects, which is exactly the
 * entity/schema drift T-3.6a was raised about.
 */
@DataJpaTest
@AutoConfigureTestDatabase(replace = AutoConfigureTestDatabase.Replace.NONE)
// The tenancy seam (T-3.10) configures Hibernate for multi-tenancy, so without a resolver the
// SessionFactory refuses every query with "no tenant identifier specified". A full-context test gets
// this by component scan; a slice has to ask for it, and the error names Hibernate rather than the
// seam that caused it.
@Import({ DefaultTenantResolver.class, DocumentRepositorySliceTest.AuditingForTheSlice.class })
@ImportTestcontainers(DatabaseTestcontainer.class)
class DocumentRepositorySliceTest {

    private static final String OWNER = "af70f9df-8441-4259-9d56-ebb6d1868ac4";
    private static final String OTHER_OWNER = "3b64215b-9126-418f-9460-7ceaf45919d2";

    // created_by / last_modified_by are NOT NULL (T-3.10's audit columns), and @DataJpaTest does
    // not enable JPA auditing -- the insert fails on a constraint that names the column and not the
    // missing auditor. A slice has to bring its own.
    @TestConfiguration
    @EnableJpaAuditing(auditorAwareRef = "sliceAuditor")
    static class AuditingForTheSlice {

        @Bean
        AuditorAware<String> sliceAuditor() {
            return () -> Optional.of("slice-test");
        }
    }

    @Autowired
    private DocumentRepository repository;

    private Document saved(String owner, Document.Status status, String filename) {
        Document d = new Document();
        d.setOwner(owner);
        d.setStatus(status);
        d.setFilename(filename);
        d.setContentType("text/plain");
        d.setSizeBytes(26L);
        d.setObjectKey("2026/08/" + filename);
        return repository.save(d);
    }

    @Test
    @DisplayName("findByIdAndOwner returns the document to its owner")
    void ownerFindsOwnDocument() {
        Document mine = saved(OWNER, Document.Status.AVAILABLE, "mine.txt");

        Optional<Document> found = repository.findByIdAndOwner(mine.getId(), OWNER);

        assertThat(found).isPresent();
        assertThat(found.orElseThrow().getFilename()).isEqualTo("mine.txt");
    }

    @Test
    @DisplayName("findByIdAndOwner refuses it to anyone else - the boundary that matters")
    void otherOwnerCannotFindIt() {
        Document mine = saved(OWNER, Document.Status.AVAILABLE, "mine.txt");

        assertThat(repository.findByIdAndOwner(mine.getId(), OTHER_OWNER)).isEmpty();
    }

    @Test
    @DisplayName("the paged listing returns only the caller's documents")
    void listingIsScopedToTheOwner() {
        saved(OWNER, Document.Status.AVAILABLE, "a.txt");
        saved(OWNER, Document.Status.AVAILABLE, "b.txt");
        saved(OTHER_OWNER, Document.Status.AVAILABLE, "theirs.txt");

        var page = repository.findByOwnerAndStatus(OWNER, Document.Status.AVAILABLE, PageRequest.of(0, 10));

        assertThat(page.getTotalElements()).isEqualTo(2);
        assertThat(page.getContent()).extracting(Document::getFilename).containsExactlyInAnyOrder("a.txt", "b.txt");
    }

    @Test
    @DisplayName("a PENDING upload is not listed - an incomplete upload is not a document yet")
    void pendingDocumentsAreNotListed() {
        saved(OWNER, Document.Status.AVAILABLE, "done.txt");
        saved(OWNER, Document.Status.PENDING, "half-uploaded.txt");

        var page = repository.findByOwnerAndStatus(OWNER, Document.Status.AVAILABLE, PageRequest.of(0, 10));

        assertThat(page.getContent()).extracting(Document::getFilename).containsExactly("done.txt");
    }
}
