package com.xenopsoftware.gateway.config;

import com.xenopsoftware.gateway.web.rest.errors.ExceptionTranslator;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.annotation.Order;
import org.springframework.data.web.ReactivePageableHandlerMethodArgumentResolver;
import org.springframework.data.web.ReactiveSortHandlerMethodArgumentResolver;
import org.springframework.util.CollectionUtils;
import org.springframework.web.cors.CorsConfiguration;
import org.springframework.web.cors.reactive.CorsConfigurationSource;
import org.springframework.web.cors.reactive.UrlBasedCorsConfigurationSource;
import org.springframework.web.reactive.config.WebFluxConfigurer;
import org.springframework.web.reactive.result.method.HandlerMethodArgumentResolver;
import org.springframework.web.server.WebExceptionHandler;
import tech.jhipster.config.JHipsterProperties;
import tech.jhipster.web.rest.errors.ReactiveWebExceptionHandler;
import tools.jackson.databind.ObjectMapper;

/**
 * Configuration of web application with Servlet 3.0 APIs.
 */
@Configuration
public class WebConfigurer implements WebFluxConfigurer {

    private static final Logger LOG = LoggerFactory.getLogger(WebConfigurer.class);

    private final JHipsterProperties jHipsterProperties;

    public WebConfigurer(JHipsterProperties jHipsterProperties) {
        this.jHipsterProperties = jHipsterProperties;
    }

    @Bean
    public CorsConfigurationSource corsConfigurationSource() {
        UrlBasedCorsConfigurationSource source = new UrlBasedCorsConfigurationSource();
        CorsConfiguration config = jHipsterProperties.getCors();
        if (!CollectionUtils.isEmpty(config.getAllowedOrigins()) || !CollectionUtils.isEmpty(config.getAllowedOriginPatterns())) {
            LOG.debug("Registering CORS filter");
            source.registerCorsConfiguration("/api/**", config);
            source.registerCorsConfiguration("/management/**", config);
            source.registerCorsConfiguration("/v3/api-docs", config);
            source.registerCorsConfiguration("/swagger-ui/**", config);
            source.registerCorsConfiguration("/*/api/**", config);
            source.registerCorsConfiguration("/services/*/api/**", config);
            source.registerCorsConfiguration("/*/management/**", config);
        }
        return source;
    }

    // TODO: remove when this is supported in spring-boot
    @Bean
    HandlerMethodArgumentResolver reactivePageableHandlerMethodArgumentResolver() {
        return new ReactivePageableHandlerMethodArgumentResolver();
    }

    // TODO: remove when this is supported in spring-boot
    @Bean
    HandlerMethodArgumentResolver reactiveSortHandlerMethodArgumentResolver() {
        return new ReactiveSortHandlerMethodArgumentResolver();
    }

    /**
     * {@code tools.jackson}, not {@code com.fasterxml.jackson}. Boot 4 ships both Jacksons and
     * this repository has beans of both types, so the wrong import compiles right up until it does
     * not: jhipster-framework 9.1.0's {@code ReactiveWebExceptionHandler} takes the Jackson 3
     * mapper, 8.12.0 took the Jackson 2 one, and the two poms had drifted onto different versions
     * of that library. Consolidating them in the parent is what surfaced this.
     */
    @Bean
    @Order(-2) // The handler must have precedence over WebFluxResponseStatusExceptionHandler and Spring Boot's ErrorWebExceptionHandler
    public WebExceptionHandler problemExceptionHandler(ObjectMapper mapper, ExceptionTranslator problemHandling) {
        return new ReactiveWebExceptionHandler(problemHandling, mapper);
    }
}
