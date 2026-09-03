package com.xenopsoftware.core.service;

import static org.assertj.core.api.Assertions.assertThat;

import com.xenopsoftware.core.IntegrationTest;
import com.xenopsoftware.core.config.CacheTestcontainer;
import com.xenopsoftware.core.config.ObjectStorageTestcontainer;
import com.xenopsoftware.core.domain.Document;
import com.xenopsoftware.core.repository.DocumentRepository;
import com.xenopsoftware.core.service.dto.CachedDocumentPage;
import java.time.Instant;
import java.util.UUID;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.data.domain.PageRequest;
import org.springframework.data.domain.Pageable;
import org.springframework.data.domain.Sort;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

/**
 * The business cache against a real Valkey (T-3.22, #264; ADR-0011).
 *
 * <p>Covers the three things the card asks to be exercised rather than asserted in a comment: that
 * a second read is actually served from the cache, that a write invalidates, and that the keys have
 * the shape ADR-0011 specified -- namespaced, versioned, and owner-scoped.
 *
 * <p>The "cache is gone" half lives in {@link DocumentCacheDegradationIT}, because it needs a
 * different context.
 */
@IntegrationTest
class DocumentCacheIT {

    @DynamicPropertySource
    static void containers(DynamicPropertyRegistry registry) {
        CacheTestcontainer.registerTo(registry);
        ObjectStorageTestcontainer.registerTo(registry);
    }

    /**
     * Fresh per test method, not shared constants.
     *
     * <p>{@code aWriteEvictsThatOwnerOnly} invalidates by SCANning {@code <owner>:*} on an
     * after-commit event. With shared ids that delete can land while the NEXT test has already
     * populated the cache, and the symptom is a key that was written a moment ago being absent --
     * which looks exactly like a caching bug and is not one. Distinct owners per method make the
     * key spaces disjoint, so no test can reach into another's.
     */
    private String owner;
    private String other;
    private static final Pageable FIRST_PAGE = PageRequest.of(0, 20, Sort.by(Sort.Direction.DESC, "createdAt"));

    @Autowired
    private DocumentService documentService;

    @Autowired
    private DocumentRepository documentRepository;

    @Autowired
    private StringRedisTemplate redis;

    @BeforeEach
    void clean() {
        documentRepository.deleteAll();
        owner = UUID.randomUUID().toString();
        other = UUID.randomUUID().toString();
    }

    /**
     * The exact key ADR-0011's format produces for one owner's first page.
     *
     * <p>Asserted key by key rather than by counting what {@code keys(pattern)} returns. Measured
     * during this work: {@code keys("*")} came back EMPTY while {@code keys("xob:c:*")} returned the
     * entry, in the same instant -- so the result of a broad pattern is not a dependable set here,
     * and a test that counts it fails intermittently for a reason that has nothing to do with the
     * cache. Naming the key is also the stricter assertion: it pins the format rather than the
     * number of entries.
     */
    private String keyFor(String forOwner) {
        return BusinessCaches.keyPrefix(BusinessCaches.DOCUMENT_LIST) + forOwner + ":0-20-" + FIRST_PAGE.getSort();
    }

    /**
     * Waits briefly for a cache entry to become visible, instead of asserting it is there instantly.
     *
     * <p>Observed while writing these tests: the entry written by {@code @Cacheable} is occasionally
     * not yet visible through this {@code StringRedisTemplate} in the same instant the service call
     * returns -- the two use different connections. Tests that happened to do a little work in
     * between passed; the two that checked immediately failed, and the same test passed in isolation
     * and under a polling loop. That is a property of observing a write through a second connection,
     * not of the cache, so the tests wait for it rather than pretending it is synchronous.
     *
     * <p>Bounded so a genuinely missing entry still fails, and fails in about two seconds.
     */
    private boolean visible(String key, boolean expected) {
        for (int i = 0; i < 40; i++) {
            if (Boolean.TRUE.equals(redis.hasKey(key)) == expected) {
                return true;
            }
            try {
                Thread.sleep(50);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                break;
            }
        }
        return false;
    }

    private Document available(String owner, String filename) {
        Document document = new Document();
        document.setOwner(owner);
        document.setFilename(filename);
        document.setContentType("text/plain");
        document.setObjectKey("2026/09/" + owner + "/" + filename);
        document.setSizeBytes(11L);
        document.setStatus(Document.Status.AVAILABLE);
        document.setCreatedAt(Instant.now());
        return documentRepository.saveAndFlush(document);
    }

    /**
     * A second identical read is served from Valkey and not from Postgres.
     *
     * <p>Proven by removing the row <em>behind the service's back</em>, straight through the
     * repository, so no invalidation event is published. A second read that still returns the
     * document can only have come from the cache. Asserting a hit any other way -- counting queries,
     * timing -- measures something else.
     */
    @Test
    void secondReadIsServedFromTheCache() {
        Document document = available(owner, "cached.txt");

        CachedDocumentPage first = documentService.listAvailableCached(owner, FIRST_PAGE);
        assertThat(first.content()).hasSize(1);
        assertThat(first.content().getFirst().filename()).isEqualTo("cached.txt");

        documentRepository.deleteById(document.getId());
        documentRepository.flush();

        CachedDocumentPage second = documentService.listAvailableCached(owner, FIRST_PAGE);
        assertThat(second.content()).as("second read should come from Valkey, not from the now-empty table").hasSize(1);
    }

    /** ADR-0011's key format, asserted against what is actually in the server. */
    @Test
    void keysAreNamespacedVersionedAndOwnerScoped() {
        available(owner, "keys.txt");
        documentService.listAvailableCached(owner, FIRST_PAGE);

        String key = keyFor(owner);
        assertThat(key)
            .as("xob:c:v<schema>:<cache>:<owner>:<discriminator>")
            .startsWith("xob:c:v1:document-list:" + owner + ":");
        assertThat(visible(key, true)).as("the entry is written under exactly ADR-0011's key").isTrue();

        // And it expires. An entry with no TTL is what ADR-0011 refuses, because under allkeys-lru
        // it lives exactly as long as nothing else needs the memory.
        Long ttl = redis.getExpire(key);
        assertThat(ttl).as("every entry carries a TTL").isNotNull().isGreaterThan(0L);
        assertThat(ttl).as("and it is the configured 300s +/-20%, not an unbounded default").isBetween(240L, 360L);
    }

    /** One owner's cached page is never reachable by another owner's read. */
    @Test
    void ownersDoNotShareEntries() {
        available(owner, "mine.txt");
        available(other, "theirs.txt");

        // Identity, not size. If the second owner's read were served from the first owner's entry a
        // size assertion would pass and hide exactly the leak this test exists to catch.
        assertThat(documentService.listAvailableCached(owner, FIRST_PAGE).content().getFirst().filename()).isEqualTo("mine.txt");
        assertThat(documentService.listAvailableCached(other, FIRST_PAGE).content().getFirst().filename())
            .as("a second owner must never be served the first owner's cached page")
            .isEqualTo("theirs.txt");

        assertThat(visible(keyFor(owner), true)).isTrue();
        assertThat(visible(keyFor(other), true))
            .as("each owner gets their own entry")
            .isTrue();
    }

    /**
     * A write invalidates the owner's cached pages, and only that owner's.
     *
     * <p>Goes through {@code DocumentService.delete}, so this exercises the real path: publish
     * inside the transaction, evict after commit. A test that published the event by hand would
     * pass while the service forgot to.
     */
    @Test
    void aWriteEvictsThatOwnerOnly() {
        Document mine = available(owner, "doomed.txt");
        available(other, "theirs.txt");

        documentService.listAvailableCached(owner, FIRST_PAGE);
        documentService.listAvailableCached(other, FIRST_PAGE);
        assertThat(visible(keyFor(owner), true)).isTrue();
        assertThat(visible(keyFor(other), true)).isTrue();

        boolean deleted = documentService.delete(mine.getId(), owner);
        assertThat(deleted).isTrue();

        assertThat(visible(keyFor(owner), false))
            .as("the writing owner's entry is gone")
            .isTrue();
        assertThat(visible(keyFor(other), true))
            .as("and nobody else paid for it")
            .isTrue();

        assertThat(documentService.listAvailableCached(owner, FIRST_PAGE).content()).isEmpty();
    }
}
