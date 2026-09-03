package com.xenopsoftware.core.service.dto;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import java.time.Instant;
import java.util.List;

/**
 * One page of document metadata, in the shape that is safe to put in Valkey (T-3.22, #264).
 *
 * <p><b>A DTO rather than the entity, which ADR-0011 requires rather than prefers:</b>
 *
 * <blockquote>An entity carries lazy proxies, identity semantics and a persistence context it
 * cannot be separated from. Serialising one either fails or silently caches an object that is not
 * equivalent to a loaded one.</blockquote>
 *
 * <p>It also lives in the service layer rather than reusing {@code DocumentResource.DocumentView},
 * because {@code TechnicalStructureTest} only lets Config and Web depend on Web. The resource maps
 * this to its own view type, which keeps the wire format free to change without silently changing
 * what is already sitting in the cache under the current schema version.
 *
 * <p><b>{@code @JsonIgnoreProperties(ignoreUnknown = true)} is load bearing.</b> ADR-0011 requires
 * that an entry written by the previous version deserialises into the new shape or is skipped,
 * never throws -- the failure mode it rejects is a deploy that adds a field and makes every
 * existing entry blow up on read rather than miss. Where a change cannot be absorbed that way, the
 * schema version in the key prefix makes the old entries unreachable instead of misread.
 *
 * <p>Deliberately NOT a {@code Page}: Spring's {@code PageImpl} has no stable JSON contract and
 * carries the {@code Pageable} that produced it. Only the two things the caller needs are stored.
 *
 * <p>The bytes of the document are not here and never will be -- ADR-0011's never-cache list is
 * explicit that object content stays in object storage, and that multi-megabyte values against a
 * bounded store is an eviction engine.
 */
@JsonIgnoreProperties(ignoreUnknown = true)
public record CachedDocumentPage(List<CachedDocument> content, long totalElements) {
    /**
     * One document's metadata.
     *
     * <p>No {@code owner} field. The owner is in the cache KEY (ADR-0011), so storing it in the
     * value would be a second copy of the thing that decides who may read the entry -- and the
     * copy that is not consulted is the one that goes wrong.
     */
    @JsonIgnoreProperties(ignoreUnknown = true)
    public record CachedDocument(Long id, String filename, String contentType, Long sizeBytes, String status, Instant createdAt) {}
}
