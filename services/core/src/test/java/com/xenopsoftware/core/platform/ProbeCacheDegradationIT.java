package com.xenopsoftware.core.platform;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;

import com.xenopsoftware.core.IntegrationTest;
import com.xenopsoftware.core.config.CacheTestcontainer;
import com.xenopsoftware.core.config.ObjectStorageTestcontainer;
import com.xenopsoftware.core.platform.CachedProbePage;
import com.xenopsoftware.core.platform.PlatformProbe;
import com.xenopsoftware.core.platform.PlatformProbeRepository;
import java.time.Instant;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.data.domain.PageRequest;
import org.springframework.data.domain.Pageable;
import org.springframework.data.domain.Sort;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

/**
 * Caching switched ON and Valkey unreachable: everything still works (T-3.22, #264).
 *
 * <p>This is the acceptance criterion of the card rather than a nice-to-have. Without a test in
 * this shape, "degrades gracefully" is <em>a sentence in a pull request rather than a property</em>.
 *
 * <p><b>Unreachable from the start, not stopped mid-test.</b> That covers all three failure points
 * the card names instead of two:
 *
 * <ol>
 *   <li><b>Startup</b> -- the context must refresh with no Valkey. Stopping a container mid-test
 *       never exercises this, and it is the one that matters most: degradation that works at
 *       runtime and fails at boot fails during a rollout, which is when Valkey is most likely to be
 *       moving anyway.
 *   <li><b>Read</b> -- a get against a dead socket must fall through to Postgres, not throw. This is
 *       the default Spring behaviour that {@code CacheConfiguration}'s error handler replaces; with
 *       the stock {@code SimpleCacheErrorHandler} every assertion below fails.
 *   <li><b>Write</b> -- a failed eviction must not fail a transaction that already committed.
 * </ol>
 *
 * <p>The fact that this class starts at all is the first assertion, and it is made by JUnit rather
 * than by a method: if the context cannot refresh without Valkey, nothing here runs.
 */
@IntegrationTest
class ProbeCacheDegradationIT {

    @DynamicPropertySource
    static void containers(DynamicPropertyRegistry registry) {
        // Caching ON, pointed at a port nothing is listening on.
        CacheTestcontainer.registerUnreachable(registry);
        ObjectStorageTestcontainer.registerTo(registry);
    }

    private static final String OWNER = "33333333-3333-3333-3333-333333333333";
    private static final Pageable FIRST_PAGE = PageRequest.of(0, 20, Sort.by(Sort.Direction.DESC, "createdAt"));

    @Autowired
    private PlatformProbeService probeService;

    @Autowired
    private PlatformProbeRepository probeRepository;

    @BeforeEach
    void clean() {
        probeRepository.deleteAll();
    }

    private PlatformProbe available(String filename) {
        PlatformProbe document = new PlatformProbe();
        document.setOwner(OWNER);
        document.setLabel(filename);
        document.setContentType("text/plain");
        document.setObjectKey("2026/09/" + OWNER + "/" + filename);
        document.setSizeBytes(11L);
        document.setStatus(PlatformProbe.Status.AVAILABLE);
        document.setCreatedAt(Instant.now());
        return probeRepository.saveAndFlush(document);
    }

    /** A read with no cache returns the right answer from Postgres rather than a 500. */
    @Test
    void readsFallThroughToTheDatabase() {
        available("still-here.txt");

        CachedProbePage page = probeService.listAvailableCached(OWNER, FIRST_PAGE);

        assertThat(page.content()).hasSize(1);
        assertThat(page.content().getFirst().label()).isEqualTo("still-here.txt");
        assertThat(page.totalElements()).isEqualTo(1);
    }

    /** And the data is correct on every call, not just the first -- nothing is being memoised locally. */
    @Test
    void repeatedReadsStayCorrectAsTheDataChanges() {
        available("one.txt");
        assertThat(probeService.listAvailableCached(OWNER, FIRST_PAGE).content()).hasSize(1);

        available("two.txt");
        assertThat(probeService.listAvailableCached(OWNER, FIRST_PAGE).content())
            .as("with no cache, every read must see the current table")
            .hasSize(2);
    }

    /**
     * A committed write does not fail because the eviction could not run.
     *
     * <p>This is the failure the card singles out as the one usually missed: a Valkey outage turning
     * every write into a 500 <em>after</em> the data was already saved. The delete must report
     * success and the row must actually be gone.
     */
    @Test
    void aFailedEvictionDoesNotFailACommittedWrite() {
        PlatformProbe document = available("doomed.txt");

        assertThatCode(() -> {
            boolean deleted = probeService.delete(document.getId(), OWNER);
            assertThat(deleted).isTrue();
        })
            .as("the eviction cannot reach Valkey, and that must not surface to the caller")
            .doesNotThrowAnyException();

        assertThat(probeRepository.findById(document.getId())).isEmpty();
        assertThat(probeService.listAvailableCached(OWNER, FIRST_PAGE).content()).isEmpty();
    }
}
