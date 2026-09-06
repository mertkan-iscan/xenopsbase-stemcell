package com.xenopsoftware.common.storage;

import java.net.URI;
import java.time.Duration;
import org.springframework.boot.autoconfigure.AutoConfiguration;
import org.springframework.boot.autoconfigure.condition.ConditionalOnMissingBean;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;
import software.amazon.awssdk.auth.credentials.DefaultCredentialsProvider;
import software.amazon.awssdk.core.client.config.ClientOverrideConfiguration;
import software.amazon.awssdk.http.apache5.Apache5HttpClient;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.S3Configuration;
import software.amazon.awssdk.services.s3.presigner.S3Presigner;

/**
 * S3 client, presigner and {@link ObjectStore} for the platform's object storage (T-3.7).
 *
 * <p>Both beans are built from {@link ObjectStoreProperties} and point at an explicit
 * endpoint. There is no AWS-specific configuration anywhere in this class, and there must not be:
 * the same code runs against Hetzner Object Storage, MinIO and R2.
 *
 * <p>Credentials come from the default provider chain, which reads {@code AWS_ACCESS_KEY_ID} and
 * {@code AWS_SECRET_ACCESS_KEY} from the environment. That is how the platform already delivers
 * them — External Secrets writes a Secret, the Deployment exposes it as env — so this needs no
 * credential handling of its own, and no credential ever passes through application config where
 * it could be logged.
 */
/**
 * <h2>Auto-configuration, not a component-scanned {@code @Configuration}</h2>
 *
 * This class no longer sits under any service's scan root, so component scanning would not find
 * it and would not say so — the beans would simply not exist, and anything conditional on them
 * would silently never fire. Registering it through
 * {@code META-INF/spring/...AutoConfiguration.imports} is what makes a service get these beans by
 * depending on this module rather than by remembering to widen a scan (ADR-0017).
 */
@AutoConfiguration
@ConditionalOnObjectStore
@EnableConfigurationProperties(ObjectStoreProperties.class)
public class StorageConfiguration {

    private final ObjectStoreProperties storage;

    public StorageConfiguration(ObjectStoreProperties storage) {
        this.storage = storage;
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

    /**
     * Every timeout stated explicitly (T-3.9).
     *
     * <p>The SDK's defaults are long rather than absent — an API call will wait minutes before
     * giving up. That is far past the point where the caller has left, and long enough that a
     * degraded object store holds request threads until the service stops answering anything.
     *
     * <p>{@code apiCallTimeout} bounds the whole operation including retries;
     * {@code apiCallAttemptTimeout} bounds one attempt. Setting only the first lets a single slow
     * attempt consume the entire budget and leave no room to retry; setting only the second means
     * three slow attempts still add up to no limit at all.
     */
    private ClientOverrideConfiguration overrideConfiguration() {
        return ClientOverrideConfiguration.builder()
            .apiCallTimeout(Duration.ofSeconds(15))
            .apiCallAttemptTimeout(Duration.ofSeconds(5))
            .build();
    }

    /**
     * Apache 5, not Apache 4. SDK 2.46 ships {@code apache5-client} as the sync transport;
     * {@code software.amazon.awssdk.http.apache} no longer exists, so the older class name fails
     * at compile time rather than silently falling back.
     */
    private Apache5HttpClient.Builder httpClient() {
        return (
            Apache5HttpClient.builder()
                .connectionTimeout(Duration.ofSeconds(2))
                .socketTimeout(Duration.ofSeconds(10))
                // Bounded on purpose. An unbounded pool turns a slow object store into unbounded
                // memory and socket use, which takes down the parts of the service that were healthy.
                .maxConnections(50)
        );
    }

    @Bean
    public S3Client s3Client() {
        return S3Client.builder()
            .endpointOverride(URI.create(storage.getEndpoint()))
            .region(Region.of(storage.getRegion()))
            .credentialsProvider(DefaultCredentialsProvider.create())
            .serviceConfiguration(serviceConfiguration())
            .overrideConfiguration(overrideConfiguration())
            .httpClientBuilder(httpClient())
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

    /**
     * Was {@code @Service} on {@link S3ObjectStore} itself. A component-scanned bean in a library
     * is only found by a service that widens its scan to this package, which is the coupling the
     * module split exists to remove — so the bean is declared here instead.
     *
     * <p>{@code @ConditionalOnMissingBean} is correct HERE and would not have been on the scanned
     * class: on an auto-configuration it is evaluated after the service's own beans are known, so
     * a fork that declares its own {@link ObjectStore} replaces this one rather than racing it.
     */
    @Bean
    @ConditionalOnMissingBean(ObjectStore.class)
    public ObjectStore objectStore(S3Client s3Client, S3Presigner s3Presigner, ObjectStoreProperties properties) {
        return new S3ObjectStore(s3Client, s3Presigner, properties);
    }
}
