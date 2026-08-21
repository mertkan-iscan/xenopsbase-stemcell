package com.xenopsoftware.core.tenancy;

import org.hibernate.cfg.AvailableSettings;
import org.hibernate.context.spi.CurrentTenantIdentifierResolver;
import org.springframework.boot.hibernate.autoconfigure.HibernatePropertiesCustomizer;
import org.springframework.stereotype.Component;

/**
 * Tells Hibernate which tenant a write belongs to and which rows a read may see (T-3.10).
 *
 * <p>Reads {@link TenantContext}, which nothing populates by default — so this resolves to
 * {@code default} for every request and the discriminator has no observable effect.
 *
 * <p>Registered by implementing {@link HibernatePropertiesCustomizer}. A bean of this type alone is
 * not enough: Hibernate reads the resolver from its own settings map, so without this the resolver
 * is constructed, never consulted, and {@code @TenantId} columns are silently left to Hibernate's
 * fallback. That is the shape of failure worth guarding against here — the seam appearing to work
 * because nothing has a reason to complain.
 */
@Component
public class DefaultTenantResolver implements CurrentTenantIdentifierResolver<String>, HibernatePropertiesCustomizer {

    @Override
    public String resolveCurrentTenantIdentifier() {
        return TenantContext.getTenant();
    }

    /**
     * True, and it matters. Hibernate validates that a cached entity belongs to the current
     * tenant; saying false lets one tenant serve another's row out of the second-level cache.
     */
    @Override
    public boolean validateExistingCurrentSessions() {
        return true;
    }

    @Override
    public void customize(java.util.Map<String, Object> hibernateProperties) {
        hibernateProperties.put(AvailableSettings.MULTI_TENANT_IDENTIFIER_RESOLVER, this);
    }
}
