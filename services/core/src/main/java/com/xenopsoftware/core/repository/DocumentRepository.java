package com.xenopsoftware.core.repository;

import com.xenopsoftware.core.domain.Document;
import java.time.Instant;
import java.util.List;
import java.util.Optional;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

@Repository
public interface DocumentRepository extends JpaRepository<Document, Long> {
    /**
     * Every read is scoped by owner rather than filtered after loading. Fetching by id and then
     * checking ownership leaks existence through timing and through the difference between 404
     * and 403; this cannot.
     */
    Optional<Document> findByIdAndOwner(Long id, String owner);

    List<Document> findByOwnerAndStatusOrderByCreatedAtDesc(String owner, Document.Status status);

    /** Backs the reaper for uploads that were presigned and never completed. */
    List<Document> findByStatusAndCreatedAtBefore(Document.Status status, Instant cutoff);
}
