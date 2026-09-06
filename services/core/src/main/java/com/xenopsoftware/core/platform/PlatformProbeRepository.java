package com.xenopsoftware.core.platform;

import java.time.Instant;
import java.util.List;
import java.util.Optional;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.stereotype.Repository;

/**
 * Reads for the platform probe, every one of them owner-scoped.
 *
 * <h2>Soft delete makes tombstoned rows invisible to everything here</h2>
 *
 * {@link PlatformProbe} carries {@code @SoftDelete}, so Hibernate adds {@code deleted = false} to
 * every query below and there is no switch to turn that off. {@link #countIncludingDeleted()} is a
 * native query precisely because JPA cannot express "including deleted" — which is the cost of the
 * mapping, stated where somebody would otherwise go looking for a flag that does not exist.
 */
@Repository
public interface PlatformProbeRepository extends JpaRepository<PlatformProbe, Long> {
    /**
     * Every read is scoped by owner rather than filtered after loading. Fetching by id and then
     * checking ownership leaks existence through timing and through the difference between 404
     * and 403; this cannot.
     */
    Optional<PlatformProbe> findByIdAndOwner(Long id, String owner);

    /**
     * Paged and sorted by the caller, but never unscoped: the owner is part of the query rather
     * than a filter applied afterwards, so page 2 cannot contain someone else's probes.
     */
    Page<PlatformProbe> findByOwnerAndStatus(String owner, PlatformProbe.Status status, Pageable pageable);

    /** Backs the reaper for uploads that were presigned and never completed. */
    List<PlatformProbe> findByStatusAndCreatedAtBefore(PlatformProbe.Status status, Instant cutoff);

    /**
     * The only way to see a tombstoned row, and it is native for a reason worth stating: JPA has
     * no "include deleted" mode under {@code @SoftDelete}, so the seam's own test cannot be written
     * through the entity manager at all. A fork that finds itself wanting more of these has
     * probably discovered that it wanted a status column rather than a soft delete.
     */
    @Query(value = "select count(*) from platform_probe", nativeQuery = true)
    long countIncludingDeleted();
}
