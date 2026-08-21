package com.xenopsoftware.core.tenancy;

/**
 * The current tenant, per request (T-3.10).
 *
 * <p><b>Inert by default.</b> Nothing populates this, so every read returns {@link #DEFAULT_TENANT}
 * and every row is written and queried under one tenant. The application behaves exactly as a
 * single-tenant application until something sets a value.
 *
 * <p>The seam exists now because the alternative is adding a tenant column to populated tables
 * later, which means deciding what every existing row belongs to and running a migration that
 * cannot be safely rolled back.
 *
 * <h2>Activating it</h2>
 *
 * Write a filter that resolves the tenant from a trusted source and calls {@link #set}, and a
 * matching {@link #clear} in a {@code finally}. The trusted source is the point: a tenant taken
 * from a request header is a tenant the caller chooses, which is not a boundary at all. It has to
 * come from something the caller cannot forge — a claim in the verified JWT is the obvious one.
 *
 * <p>Threads are pooled, so failing to clear leaks one request's tenant into the next request that
 * reuses the thread. That failure reads as data from the wrong tenant appearing intermittently
 * under load, which is the worst way to discover it.
 */
public final class TenantContext {

    /** What every row gets while the seam is inert. Never null: a null tenant matches no filter. */
    public static final String DEFAULT_TENANT = "default";

    private static final ThreadLocal<String> CURRENT = new ThreadLocal<>();

    private TenantContext() {}

    public static String getTenant() {
        String tenant = CURRENT.get();
        return tenant == null ? DEFAULT_TENANT : tenant;
    }

    public static void set(String tenant) {
        CURRENT.set(tenant);
    }

    public static void clear() {
        CURRENT.remove();
    }
}
