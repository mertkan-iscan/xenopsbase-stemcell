package com.xenopsoftware.core.platform;

/**
 * One owner's probe set changed in a way that makes their cached pages wrong (T-3.22, #264).
 *
 * <p>Published inside the transaction and consumed <b>after commit</b>. ADR-0011 requires that
 * ordering rather than suggesting it:
 *
 * <blockquote>An eviction that fires before the commit opens a window in which a concurrent reader
 * repopulates the cache from the pre-commit state, and that entry then survives the commit -- a
 * stale entry created <em>by</em> the invalidation.</blockquote>
 *
 * <p>Carrying the owner rather than the probe id, because the cached unit is a page of one
 * owner's probes and any change to the set invalidates every page of it. A probe id would
 * not identify a single cache key: the same row appears on whichever page the sort puts it on, and
 * inserting one shifts every page after it.
 *
 * <p>If nothing is listening -- caching switched off, or Valkey absent -- publishing this is a
 * no-op, which is what lets the write path stay identical in both cases.
 */
public record ProbesChanged(String owner) {}
