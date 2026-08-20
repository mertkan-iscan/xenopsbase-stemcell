package com.xenopsoftware.core.config;

import java.net.URI;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.testcontainers.containers.MinIOContainer;
import software.amazon.awssdk.auth.credentials.AwsBasicCredentials;
import software.amazon.awssdk.auth.credentials.StaticCredentialsProvider;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.S3Configuration;
import software.amazon.awssdk.services.s3.model.BucketAlreadyOwnedByYouException;
import software.amazon.awssdk.services.s3.model.CreateBucketRequest;

/**
 * MinIO for document-storage tests (T-3.7).
 *
 * <p>A real S3 implementation rather than a mock, on purpose. The parts of this feature that break
 * in practice are the parts a mock cannot have opinions about: whether a presigned signature
 * actually validates, whether path-style addressing is required, whether the content-length
 * condition is enforced by the server. A mocked {@code DocumentStorage} would pass while the
 * deployed service returned 403 on every upload.
 *
 * <p><b>Why this is a singleton holder and not an {@code @ImportTestcontainers} interface, unlike
 * {@link DatabaseTestcontainer}.</b> Properties registered through {@code @ImportTestcontainers}
 * are applied by a bean during context refresh, which is <em>after</em> {@code @Configuration}
 * class conditions have been evaluated. {@code StorageConfiguration} is
 * {@code @ConditionalOnProperty} on the bucket name, so it saw nothing and no {@code S3Client} bean
 * was ever created — while the container itself started perfectly, which made it look like a wiring
 * bug rather than an ordering one.
 *
 * <p>A {@code @DynamicPropertySource} method declared on the test class is applied by the
 * TestContext framework <em>before</em> refresh, so conditions see the values. Hence
 * {@link #registerTo(DynamicPropertyRegistry)}, called from the test class itself.
 */
public final class ObjectStorageTestcontainer {

    public static final String BUCKET = "test-documents";
    private static final String ACCESS_KEY = "testaccesskey";
    private static final String SECRET_KEY = "testsecretkey";

    /** Started once per JVM and shared. Testcontainers stops it via its own shutdown hook. */
    private static final MinIOContainer CONTAINER = new MinIOContainer("minio/minio:RELEASE.2025-04-22T22-12-26Z")
        .withUserName(ACCESS_KEY)
        .withPassword(SECRET_KEY);

    private ObjectStorageTestcontainer() {}

    public static void registerTo(DynamicPropertyRegistry registry) {
        if (!CONTAINER.isRunning()) {
            CONTAINER.start();
            createBucket();
        }

        registry.add("application.storage.bucket", () -> BUCKET);
        registry.add("application.storage.endpoint", CONTAINER::getS3URL);
        registry.add("application.storage.region", () -> "us-east-1");
        registry.add("application.storage.path-style-access", () -> true);

        // Production code reads credentials from the default AWS chain, which is the environment.
        // A test cannot set environment variables for the JVM it is already running in, so these
        // go in as system properties — the same chain, a different link.
        System.setProperty("aws.accessKeyId", ACCESS_KEY);
        System.setProperty("aws.secretAccessKey", SECRET_KEY);
    }

    /**
     * Terraform creates the bucket in every real environment. Nothing does here, and an S3 client
     * against a missing bucket fails at the first call rather than at startup, which reads as a
     * code fault.
     */
    private static void createBucket() {
        try (
            S3Client client = S3Client.builder()
                .endpointOverride(URI.create(CONTAINER.getS3URL()))
                .region(Region.US_EAST_1)
                .credentialsProvider(StaticCredentialsProvider.create(AwsBasicCredentials.create(ACCESS_KEY, SECRET_KEY)))
                .serviceConfiguration(S3Configuration.builder().pathStyleAccessEnabled(true).chunkedEncodingEnabled(false).build())
                .build()
        ) {
            client.createBucket(CreateBucketRequest.builder().bucket(BUCKET).build());
        } catch (BucketAlreadyOwnedByYouException e) {
            // Already there. Fine.
        }
    }
}
