package com.xenopsoftware.common.service;

import java.util.Map;
import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * Where the other services are (T-9.4), by name rather than by URL at the call site.
 *
 * <p>Named targets rather than arbitrary ones, deliberately: a relay that takes a URL from a
 * caller is a server-side request forgery hole, and one that takes a name can only reach somewhere
 * an operator configured. That is the whole reason this indirection exists — it is not a
 * convenience for shortening call sites.
 *
 * <pre>
 * platform:
 *   services:
 *     endpoints:
 *       reporting: http://reporting.apps.svc.cluster.local:8081
 * </pre>
 *
 * <p>Empty by default. The template ships with one service, which calls nothing.
 */
@ConfigurationProperties(prefix = "platform.services")
public record ServiceEndpoints(Map<String, String> endpoints) {
    public ServiceEndpoints {
        endpoints = endpoints == null ? Map.of() : Map.copyOf(endpoints);
    }

    /**
     * @throws IllegalArgumentException naming what IS configured. A misspelled service name is the
     *                                  likeliest cause, and an exception that lists the known names
     *                                  answers that in one line instead of sending somebody to the
     *                                  ConfigMap.
     */
    public String baseUrlOf(String service) {
        String url = endpoints.get(service);
        if (url == null) {
            throw new IllegalArgumentException("No endpoint configured for service '" + service + "'; known: " + endpoints.keySet());
        }
        return url;
    }
}
