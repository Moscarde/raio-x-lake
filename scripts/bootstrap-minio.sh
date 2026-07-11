#!/bin/sh
# Creates MinIO buckets, policies, and unprivileged application identities.
set -eu

ENV_FILE=${MINIO_ENV_FILE:-./.env}
APPLICATION_ENV_FILE=${MINIO_APPLICATION_ENV_FILE:-./.minio.application.env}
COMPOSE_FILE=${MINIO_COMPOSE_FILE:-docker-compose.minio.yml}
NETWORK=${MINIO_NETWORK:-raio-x-data}
MC_IMAGE=${MC_IMAGE:-minio/mc:latest}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

[ -r "$ENV_FILE" ] || die "Missing MinIO environment file: $ENV_FILE"

set -a
. "$ENV_FILE"
set +a

: "${MINIO_ROOT_USER:?MINIO_ROOT_USER must be set}"
: "${MINIO_ROOT_PASSWORD:?MINIO_ROOT_PASSWORD must be set}"

if [ -r "$APPLICATION_ENV_FILE" ]; then
  set -a
  . "$APPLICATION_ENV_FILE"
  set +a
fi

generate_application_credentials() {
  umask 077
  prod_access_key="rxprod$(openssl rand -hex 7)"
  prod_secret_key=$(openssl rand -base64 48 | tr -d '\n')
  dev_access_key="rxdev$(openssl rand -hex 7)"
  dev_secret_key=$(openssl rand -base64 48 | tr -d '\n')

  credentials_tmp=$(mktemp "${APPLICATION_ENV_FILE}.XXXXXX")
  printf '%s\n' \
    "OBJECT_STORAGE_ACCESS_KEY=$prod_access_key" \
    "OBJECT_STORAGE_SECRET_KEY=$prod_secret_key" \
    "OBJECT_STORAGE_DEV_ACCESS_KEY=$dev_access_key" \
    "OBJECT_STORAGE_DEV_SECRET_KEY=$dev_secret_key" > "$credentials_tmp"
  chmod 600 "$credentials_tmp"
  mv "$credentials_tmp" "$APPLICATION_ENV_FILE"

  OBJECT_STORAGE_ACCESS_KEY=$prod_access_key
  OBJECT_STORAGE_SECRET_KEY=$prod_secret_key
  OBJECT_STORAGE_DEV_ACCESS_KEY=$dev_access_key
  OBJECT_STORAGE_DEV_SECRET_KEY=$dev_secret_key
}

if [ -z "${OBJECT_STORAGE_ACCESS_KEY:-}" ] || [ -z "${OBJECT_STORAGE_SECRET_KEY:-}" ] || \
   [ -z "${OBJECT_STORAGE_DEV_ACCESS_KEY:-}" ] || [ -z "${OBJECT_STORAGE_DEV_SECRET_KEY:-}" ]; then
  generate_application_credentials
fi

container_id=$(docker compose -f "$COMPOSE_FILE" ps -q minio)
[ -n "$container_id" ] || die "MinIO container is not running; start it before bootstrap"

attempt=0
until [ "$(docker inspect --format '{{.State.Health.Status}}' "$container_id")" = "healthy" ]; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 61 ] || die "MinIO did not become healthy within 5 minutes"
  sleep 5
done

mc_config_dir=$(mktemp -d)
policy_dir=$(mktemp -d)
cleanup() {
  rm -rf "$mc_config_dir" "$policy_dir"
}
trap cleanup 0 HUP INT TERM

mc() {
  docker run --rm \
    --network "$NETWORK" \
    --user "$(id -u):$(id -g)" \
    -v "$mc_config_dir:/config" \
    -v "$policy_dir:/policies:ro" \
    "$MC_IMAGE" --config-dir /config "$@"
}

mc alias set local http://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null

for bucket in \
  raio-x-landing-prod raio-x-lake-prod raio-x-artifacts-prod \
  raio-x-landing-dev raio-x-lake-dev raio-x-artifacts-dev; do
  mc mb --ignore-existing "local/$bucket" >/dev/null
done

write_policy() {
  environment=$1
  policy_file="$policy_dir/raio-x-$environment.json"
  printf '%s\n' \
    '{' \
    '  "Version": "2012-10-17",' \
    '  "Statement": [' \
    '    {' \
    '      "Effect": "Allow",' \
    '      "Action": ["s3:ListBucket", "s3:GetBucketLocation"],' \
    "      \"Resource\": [\"arn:aws:s3:::raio-x-landing-$environment\", \"arn:aws:s3:::raio-x-lake-$environment\", \"arn:aws:s3:::raio-x-artifacts-$environment\"]" \
    '    },' \
    '    {' \
    '      "Effect": "Allow",' \
    '      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],' \
    "      \"Resource\": [\"arn:aws:s3:::raio-x-landing-$environment/*\", \"arn:aws:s3:::raio-x-lake-$environment/*\", \"arn:aws:s3:::raio-x-artifacts-$environment/*\"]" \
    '    }' \
    '  ]' \
    '}' > "$policy_file"
}

write_policy prod
write_policy dev

for environment in prod dev; do
  policy_name="raio-x-$environment-rw"
  policy_file="$policy_dir/raio-x-$environment.json"
  if ! mc admin policy info local "$policy_name" >/dev/null 2>&1; then
    mc admin policy create local "$policy_name" "/policies/raio-x-$environment.json" >/dev/null
  fi
done

mc admin user add local "$OBJECT_STORAGE_ACCESS_KEY" "$OBJECT_STORAGE_SECRET_KEY" >/dev/null
mc admin policy attach local raio-x-prod-rw --user "$OBJECT_STORAGE_ACCESS_KEY" >/dev/null
mc admin user add local "$OBJECT_STORAGE_DEV_ACCESS_KEY" "$OBJECT_STORAGE_DEV_SECRET_KEY" >/dev/null
mc admin policy attach local raio-x-dev-rw --user "$OBJECT_STORAGE_DEV_ACCESS_KEY" >/dev/null

printf '%s\n' "MinIO bootstrap completed. Application credentials are stored only in $APPLICATION_ENV_FILE."
