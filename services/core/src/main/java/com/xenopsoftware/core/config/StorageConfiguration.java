package com.xenopsoftware.core.config;

import java.net.URI;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import software.amazon.awssdk.auth.credentials.DefaultCredentialsProvider;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.S3Configuration;
import software.amazon.awssdk.services.s3.presigner.S3Presigner;

/**
 * S3 client and presigner for document storage (T-3.7).
 *
 * <p>Both beans are built from {@link ApplicationProperties.Storage} and point at an explicit
 * endpoint. There is no AWS-specific configuration anywhere in this class, and there must not be:
 * the same code runs against Hetzner Object Storage, MinIO and R2.
 *
 * <p>Credentials come from the default provider chain, which reads {@code AWS_ACCESS_KEY_ID} and
 * {@code AWS_SECRET_ACCESS_KEY} from the environment. That is how the platform already delivers
 * them — External Secrets writes a Secret, the Deployment exposes it as env — so this needs no
 * credential handling of its own, and no credential ever passes through application config where
 * it could be logged.
 */
@Configuration
@ConditionalOnDocumentStorage
public class StorageConfiguration {

    private final ApplicationProperties.Storage storage;

    public StorageConfiguration(ApplicationProperties properties) {
        this.storage = properties.getStorage();
    }

    private S3Configuration serviceConfiguration() {
        return S3Configuration.builder()
            // Virtual-host style would need wildcard DNS and a wildcard certificate per bucket,
            // which self-hosted S3 implementations generally do not have.
            .pathStyleAccessEnabled(storage.isPathStyleAccess())
            // Checksums are computed and sent by default in recent SDK versions. Several
            // S3-compatible providers reject the extra trailing-checksum headers outright, and
            // the failure surfaces as an opaque 400 rather than as anything about checksums.
            .chunkedEncodingEnabled(false)
            .build();
    }

    @Bean
    public S3Client s3Client() {
        return S3Client.builder()
            .endpointOverride(URI.create(storage.getEndpoint()))
            .region(Region.of(storage.getRegion()))
            .credentialsProvider(DefaultCredentialsProvider.create())
            .serviceConfiguration(serviceConfiguration())
            .build();
    }

    @Bean
    public S3Presigner s3Presigner() {
        return S3Presigner.builder()
            .endpointOverride(URI.create(storage.getEndpoint()))
            .region(Region.of(storage.getRegion()))
            .credentialsProvider(DefaultCredentialsProvider.create())
            .serviceConfiguration(serviceConfiguration())
            .build();
    }
}
