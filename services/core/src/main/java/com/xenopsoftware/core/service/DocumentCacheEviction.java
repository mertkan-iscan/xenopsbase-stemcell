package com.xenopsoftware.core.service;

import java.util.ArrayList;
import java.util.List;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.data.redis.core.Cursor;
import org.springframework.data.redis.core.ScanOptions;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.event.TransactionPhase;
import org.springframework.transaction.event.TransactionalEventListener;

/**
 * Invalidates one owner's cached document pages, after the transaction that changed them committed
 * (T-3.22, #264).
 *
 * <p><b>Why this is not a {@code @CacheEvict}.</b> ADR-0011 forbids the obvious version:
 *
 * <blockquote>Evictions therefore run on transaction synchronisation after commit
 * ({@code @TransactionalEventListener(AFTER_COMMIT)} or an explicit {@code
 * TransactionSynchronization}), never as a bare {@code @CacheEvict} on a {@code @Transactional}
 * method.</blockquote>
 *
 * <p>A bare {@code @CacheEvict} fires while the transaction is still open, so a concurrent reader
 * can repopulate the cache from the pre-commit state and that entry then outlives the commit --
 * a stale entry created by the invalidation itself. {@code AFTER_COMMIT} closes that window.
 *
 * <p><b>Why a SCAN and not {@code Cache.evict}.</b> The cached unit is a page, and a document
 * appears on whichever page the sort puts it on, so a single write can invalidate every page an
 * owner has. Spring's {@code Cache} abstraction offers one key or the whole cache; the whole cache
 * would cost every other user their entries for one user's upload. Scanning ADR-0011's owner
 * prefix -- {@code xob:c:v1:document-list:<owner>:*} -- invalidates exactly the right set, and it
 * is possible only because the owner is IN the key, which is the same property that stops one
 * user's cached page being served to another.
 *
 * <p><b>Why nothing here can fail a request.</b> The transaction has already committed by the time
 * this runs, so there is nothing left to roll back, and every failure is swallowed with a warning.
 * ADR-0011 names the consequence rather than pretending it away: <em>a write whose eviction did not
 * run serves stale reads for up to one TTL.</em> That is what the mandatory TTL bounds, and it is
 * the reason the TTL exists at all.
 */
@Component
@ConditionalOnProperty(name = "application.cache.enabled", havingValue = "true")
public class DocumentCacheEviction {

    private static final Logger LOG = LoggerFactory.getLogger(DocumentCacheEviction.class);

    /** Keys per SCAN round trip. Large enough not to chatter, small enough not to block the server. */
    private static final int SCAN_BATCH = 256;

    private final StringRedisTemplate redis;

    public DocumentCacheEviction(StringRedisTemplate redis) {
        this.redis = redis;
    }

    @TransactionalEventListener(phase = TransactionPhase.AFTER_COMMIT)
    public void onDocumentsChanged(DocumentsChanged event) {
        String pattern = BusinessCaches.ownerKeyPattern(BusinessCaches.DOCUMENT_LIST, event.owner());
        try {
            List<String> keys = new ArrayList<>();
            try (Cursor<String> cursor = redis.scan(ScanOptions.scanOptions().match(pattern).count(SCAN_BATCH).build())) {
                cursor.forEachRemaining(keys::add);
            }
            if (!keys.isEmpty()) {
                redis.delete(keys);
            }
            LOG.debug("Evicted {} cached document pages matching {}", keys.size(), pattern);
        } catch (RuntimeException e) {
            // Deliberately swallowed. The write is committed; failing here would report an error
            // for data that was saved, which is the failure mode T-3.22 exists to prevent. The
            // stale entries this leaves behind are bounded by their TTL.
            LOG.warn("Could not evict cached document pages matching {}; entries expire under their TTL instead", pattern, e);
        }
    }
}
