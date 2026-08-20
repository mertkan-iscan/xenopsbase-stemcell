# Runbook: document storage

Metadata in Postgres, bytes in a bucket, and **no byte ever passes through the JVM**.

## The shape of it

```
client ──POST /api/documents {size}───────▶ core      row written PENDING
       ◀─────────── { id, uploadUrl } ─────
       ──PUT uploadUrl───────────────────▶ bucket     bytes go here, not through core
       ──POST /api/documents/{id}/complete▶ core      HEAD the object, promote to AVAILABLE
       ◀────────────────────── 200 ────────

       ──GET  /api/documents/{id}/download▶ core      302 to a presigned GET
       ──GET  <presigned>────────────────▶ bucket
```

| | |
|---|---|
| Bucket | `<prefix>-<env>-documents`, created by `infra/terraform/storage` |
| Metadata | `document` table, `V3__document.sql` |
| Seam | `service/storage/DocumentStorage` — S3 API only |
| Implementation | `S3DocumentStorage`, AWS SDK v2 used purely as an S3 client |
| Local and test | MinIO via Testcontainers |
| Deployed | Hetzner Object Storage |

## Why the service never touches the bytes

Proxying uploads would put core on the critical path for something the object store does better.
A 50 MB upload becomes heap and socket cost on every replica, one slow client contends with every
other request, and the upload path stops being independently scalable. Presigned URLs move that
work to the store, which is what it is for.

The cost is that a presigned URL is a **bearer credential**. Whoever holds it can read or write
that object with no further authentication, and it will end up in browser history, proxy logs and
pasted links. Two things bound the damage:

- **TTL is 15 minutes** (`application.storage.presign-ttl`). This is the only thing limiting a
  leaked URL, so lengthening it is a security decision, not a convenience one.
- **The download redirect sets `Cache-Control: no-store`.** Without it a caching proxy could hand
  one user's signed URL to the next caller.

### Upload size

The client **declares the exact size up front**, and that number is what gets signed.

This is not a stylistic choice. `contentLength` on a presigned PUT is signed as an **exact value,
not a ceiling** — S3 has no way to presign "at most N bytes" with a plain PUT. Signing the
configured maximum and hoping smaller uploads pass does not work: every upload of any other size
fails the signature check and comes back `403`, which reads as a credentials problem and is not.

So there are two mechanisms, doing different jobs:

| | enforced by | rejects |
|---|---|---|
| `max-upload-bytes` | the service, before signing | `413` at initiate |
| declared size | the object store, via the signature | `403` at PUT |

Together that is a real limit. The service caps what it will sign, and the store refuses anything
that does not match what was signed — so a client cannot inflate its upload after the fact.

`POST` policies do support a `content-length-range` condition, which would allow a true range. The
Java SDK v2 has no first-class support for presigned POST, and a declared size is simpler for
callers than a policy document, so this template does not use them.

## The consistency story

Postgres and the bucket cannot share a transaction. Rather than pretend otherwise, the ordering
is chosen so the surviving inconsistency is always the harmless one.

| Step | Order | If it fails halfway |
|---|---|---|
| Upload | row, **then** object | Row with no object. Invisible to users, reaped later. |
| Complete | object confirmed, **then** row promoted | Stays `PENDING`. Not downloadable. |
| Delete | row, **then** object | Object with no row: garbage that costs storage. |

The inverse of any of these is worse. Writing the object first makes an interrupted upload produce
unreferenced data nothing can find, delete or account for. Deleting the object first makes a
rollback leave a row pointing at bytes that are gone — a download that 404s at the worst moment.

**Only `AVAILABLE` documents are downloadable**, and a document becomes `AVAILABLE` only after the
service asks the store whether the object is really there. A client reporting success proves
nothing; that is what a client would report either way.

### Cleaning up abandoned uploads

`DocumentService.reapAbandonedUploads(Instant)` deletes `PENDING` rows older than a cutoff, and
their objects — an upload can complete after the client gave up, leaving bytes behind a row nobody
will promote.

It is deliberately **not** `@Scheduled`. A schedule baked into the template runs on every replica
at once. Wire it to a CronJob, a `ShedLock`-guarded task, or nothing, per deployment. The cutoff
must be comfortably longer than the presign TTL or it deletes uploads still legitimately in
flight.

## Ownership

Documents are keyed on the OIDC **`sub`**, via `SecurityUtils.getCurrentUserId()`.

Not `preferred_username`. A username can be changed in Keycloak at any time, and every document
owned under the old one would silently become unreachable — no error, no migration path. `sub`
never changes for the life of the account.

Every lookup is scoped by owner **in the repository query**, not filtered after loading. Someone
else's document is indistinguishable from one that does not exist: both are 404. Loading first and
checking after leaks existence through the 403/404 difference and through timing.

## Portability

The seam targets the S3 API and nothing else. `S3DocumentStorage` uses only calls that exist in
every S3-compatible implementation: `PutObject`, `GetObject`, `HeadObject`, `DeleteObject`, and
presigning. Reaching for an AWS-only feature — storage classes, S3 Select, bucket notifications —
would make the template unportable without any test failing, so it is the thing to watch for in
review.

Two settings exist because of that portability, not despite it:

- **`path-style-access: true`.** Virtual-host style (`bucket.endpoint/key`) needs wildcard DNS and
  a wildcard certificate per bucket, which self-hosted providers generally do not have.
- **`chunkedEncodingEnabled(false)`.** Recent SDK versions send trailing checksum headers by
  default; several S3-compatible providers reject them, and the failure surfaces as an opaque 400
  with nothing about checksums in it.

## Configuration

```yaml
application:
  storage:
    bucket: xenopsbase-dev-documents
    endpoint: https://fsn1.your-objectstorage.com
    region: us-east-1
    path-style-access: true
    presign-ttl: 15m
    max-upload-bytes: 52428800
```

`bucket` and `endpoint` are **unset in `application.yml` on purpose**. Leave them unset and the
whole feature is absent: `@ConditionalOnDocumentStorage` is on the configuration, the storage
implementation, the service *and* the controller, so a fork that does not need documents carries no
S3 client, no endpoints, and nothing to maintain.

Annotating only the configuration is not enough, and this is worth knowing before someone
"simplifies" it. The service and the storage implementation are component-scanned, so without the
annotation they are still created, fail to find an `S3Client`, and take the entire application
context down — making the feature mandatory while the docs call it optional. The Cucumber context
configures no bucket and is the standing proof that the application boots without it.

`application-prod.yml` has no default for either value: a wrong default writes documents into
another environment's bucket, and nothing reports an error.

**Credentials are never in configuration.** The SDK's default chain reads `AWS_ACCESS_KEY_ID` and
`AWS_SECRET_ACCESS_KEY` from the environment, which is how the platform already delivers them —
External Secrets writes a Secret, the Deployment exposes it as env. Nothing passes through
application config, where it could be logged.

## Running it locally

`application-dev.yml` points at `http://localhost:9000`. Nothing in this repository starts that
yet — the generator's compose files were deleted with the rest of the generator (T-3.4), and the
local stack is T-4.1's job, not this one. Until then:

```bash
docker run -d --name xenopsbase-minio -p 9000:9000 -p 9001:9001   -e MINIO_ROOT_USER=minioadmin -e MINIO_ROOT_PASSWORD=minioadmin   minio/minio server /data --console-address ":9001"
```

The bucket has to exist — Terraform creates it in every real environment and nothing creates it
here. Make it once via the console on `:9001`, or with any S3 client, named to match
`DOCUMENTS_BUCKET`.

Credentials come from the environment, the same as in a deployed environment:

```bash
export AWS_ACCESS_KEY_ID=minioadmin AWS_SECRET_ACCESS_KEY=minioadmin
```

The integration tests need none of this — Testcontainers starts and configures its own MinIO.

## Verifying

```bash
cd services/core && ./mvnw verify -DskipITs=false -Dit.test=DocumentResourceIT
```

`DocumentResourceIT` runs against real MinIO and genuinely PUTs and GETs the bytes over the
presigned URLs with an `HttpClient`, outside the application. That matters: a mocked
`DocumentStorage` cannot have an opinion about whether a signature validates, whether path-style
addressing is required, or whether the length condition is enforced — so it would pass while the
deployed service returned 403 on every upload.

## Known gaps

**No multipart upload.** A single presigned PUT caps out around 5 GB by S3 rules, and
`max-upload-bytes` is 50 MB anyway. Anything larger needs `CreateMultipartUpload` and a presigned
URL per part, which is a different API shape and belongs with whatever needs it.

**No virus scanning and no content-type verification.** The service signs for the content type the
client declares and never sees the bytes, so it cannot check that the declaration is true. A
deployment that accepts untrusted uploads needs a scanner triggered on the bucket, not a check
here — checking here would require proxying the bytes, which is the thing this design exists to
avoid.

**Bucket lifecycle does not expire anything.** Documents are user data (see
`infra/terraform/storage`). Abandoned objects are handled by the reaper above, not by a lifecycle
rule, because a rule cannot tell an abandoned upload from a document someone has not opened yet.
