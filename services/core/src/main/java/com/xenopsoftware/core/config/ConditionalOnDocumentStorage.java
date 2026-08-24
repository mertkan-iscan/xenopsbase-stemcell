package com.xenopsoftware.core.config;

import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;

/**
 * Present only when a documents bucket is configured (T-3.7).
 *
 * <p>Applied to <em>every</em> bean in the document-storage feature, not just the configuration
 * that builds the S3 client. Guarding only the client is not enough: {@code DocumentService} and
 * {@code S3DocumentStorage} are component-scanned, so they would still be created, fail to find an
 * {@code S3Client}, and take the entire application context down with them.
 *
 * <p>That is not hypothetical — it is what happened. Every context without storage configured
 * refused to start, which meant the feature was mandatory while being documented as optional. The
 * Cucumber context, which configures no bucket, is what caught it and is now the standing proof
 * that the application boots without this feature.
 *
 * <p>The upshot for a fork: leave {@code application.storage.bucket} unset and the whole feature —
 * client, service and endpoints — is simply absent. No dead beans, no S3 client, no configuration
 * to maintain for something unused.
 */
@Target({ ElementType.TYPE, ElementType.METHOD })
@Retention(RetentionPolicy.RUNTIME)
@ConditionalOnProperty(prefix = "application.storage", name = "bucket")
public @interface ConditionalOnDocumentStorage {}
