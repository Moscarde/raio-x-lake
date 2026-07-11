# MinIO object storage

This repository operates a single-node, S3-compatible MinIO deployment for
`raio-x-engenharia` on `2.25.172.31`. It stores Parquet data in landing, raw,
staging, and intermediate layers. PostgreSQL remains reserved for gold data:
dimensions, facts, and marts. Collectors and dbt are not migrated to Parquet
by this deployment.

MinIO runs on the external Docker network `raio-x-data`. The Astro scheduler
is operated from a separate repository and must join that network to resolve
`http://minio:9000`.

## Security limits

Plain public HTTP is not suitable for permanent credentials or sensitive data.
This Compose deployment binds MinIO only to VPS loopback, so it is accessed
through SSH tunneling. If direct public access is enabled in the future, it
must be restricted by firewall to the approved administrative source IP and
credentials must not be used over an untrusted network.

MinIO is single-node and runs on the same VPS as its data. It has no high
availability and is not a substitute for tested external backups.

## Initial installation

Run the following only on the VPS. Do not place credentials in this repository,
shell history, terminal output, logs, or documentation.

1. Install Docker Engine with the Compose plugin and create the persistent
   directory with restricted ownership appropriate for the Docker service:

   ```sh
   sudo install -d -m 0700 /srv/raio-x/minio/data
   sudo docker network inspect raio-x-data >/dev/null 2>&1 || sudo docker network create raio-x-data
   ```

2. Generate the root environment directly on the VPS. The initializer uses
   `openssl` to create a high-entropy password and writes it only to `.env`
   with mode `0600`:

   ```sh
   ./scripts/initialize-minio-env.sh
   ```

   Do not use `Cacto_PASS`; it is only a placeholder from the original
   requirements and does not meet the entropy requirement. Store a recovery
   copy in an approved secret manager, not terminal output, shell history, or
   this repository.

3. Validate and start MinIO:

   ```sh
   docker compose -f docker-compose.minio.yml config --quiet
   just up
   ```

`just up` creates the shared Docker network, generates `.env` if absent,
starts MinIO, and runs the bootstrap. Use `just down` to stop MinIO without
removing data. `just reset DELETE-MINIO-DATA` irreversibly deletes all objects,
generated application credentials, and the local persistent data directory.

The bootstrap waits for the container healthcheck, creates all prod and dev
buckets, then creates policies and unprivileged application users. It writes
generated application credentials only to `.minio.application.env` with mode
`0600`; this file is Git-ignored and is never printed by the script.

Transfer the production credentials to the Astro deployment through its
existing secret mechanism. Do not copy root credentials to Airflow. The dev
credentials are intended only for development clients.

## Buckets and access policies

Production users can list, read, write, and delete objects only in:

- `raio-x-landing-prod`
- `raio-x-lake-prod`
- `raio-x-artifacts-prod`

Development users receive the same operations only for the corresponding
`-dev` buckets. Neither application user receives MinIO administration rights.
The root account is exclusively for console and administration.

## Firewall and remote access

The only approved administrative source IP is `200.97.62.226`. Before exposing
the Compose-published ports, review existing firewall rules and preserve SSH
access. With UFW and a default-deny incoming policy, allow only that address:

```sh
sudo ufw allow proto tcp from 200.97.62.226 to any port 9000
sudo ufw allow proto tcp from 200.97.62.226 to any port 9001
sudo ufw status numbered
```

Remove any existing broad rules permitting TCP ports `9000` or `9001` from all
sources. Never add rules allowing these ports from `0.0.0.0/0`. Apply equivalent
source-specific rules if the VPS uses nftables, iptables, or a cloud firewall.
Confirm from a non-authorized network that both ports are blocked.

This deployment does not expose either port publicly. Access it from an
authorized machine through:

```sh
ssh -L 9000:localhost:9000 -L 9001:localhost:9001 usuario@2.25.172.31
```

Then use `http://localhost:9000` and `http://localhost:9001`. The console is
protected by MinIO's own root credentials; it must not be shared with
applications.

## Astro integration contract

The Astro repository owns its Compose override. Its scheduler service must join
the pre-existing external network `raio-x-data` and receive, via its own secret
management, the production application credentials and these values:

```dotenv
OBJECT_STORAGE_ENDPOINT=http://minio:9000
OBJECT_STORAGE_EXTERNAL_ENDPOINT=http://2.25.172.31:9000
OBJECT_STORAGE_REGION=us-east-1
OBJECT_STORAGE_SECURE=false
OBJECT_STORAGE_LANDING_BUCKET=raio-x-landing-prod
OBJECT_STORAGE_LAKE_BUCKET=raio-x-lake-prod
OBJECT_STORAGE_ARTIFACTS_BUCKET=raio-x-artifacts-prod
```

From the scheduler container, validate DNS and liveness without exposing
secrets: resolve `minio`, then request
`http://minio:9000/minio/health/live`. The scheduler must use the prod user,
not the root account.

## Operational checks

Check service state and logs without enabling shell tracing:

```sh
docker compose -f docker-compose.minio.yml ps
docker compose -f docker-compose.minio.yml logs --tail=100 minio
```

To test access controls, use `mc` with short-lived shell environment variables
loaded from the protected credential file. Verify both users can create and
list an object in their own bucket, then verify the dev identity receives
`Access Denied` for a prod bucket. Never include secrets as command arguments
or paste them into logs.

## Backup and restore

Back up all buckets to storage outside this VPS on a schedule. Use `mc mirror`
with a dedicated, least-privileged backup identity and an external S3-compatible
destination. Enable versioning and retention at the destination where its
policy supports them. Monitor backup completion and routinely test restore.

For restore, stop writers, mirror the required external backup prefix back to
resume writers. Do not rely on copying `/srv/raio-x/minio/data` while MinIO is
running as a replacement for an object-level, tested external backup.

## Credential rotation

1. Generate a replacement application secret directly on the VPS.
2. Update the relevant MinIO application user with `mc admin user add` using
   the existing access key and replacement secret.
3. Update the consuming deployment's protected secret and restart/reload it.
4. Validate the new credentials, revoke any obsolete identity if a new access
   key was issued, and record the rotation in the operational secret system.

Rotate the root account separately during a maintenance window: update the
protected `.env`, restart MinIO, authenticate to the console, and confirm that
application users remain functional. Never rotate by committing credentials or
by printing them to logs.
