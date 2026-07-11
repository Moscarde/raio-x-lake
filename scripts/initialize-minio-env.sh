#!/bin/sh
# Creates the local root-credential environment file without printing secrets.
set -eu

ENV_FILE=${MINIO_ENV_FILE:-./.env}

[ ! -e "$ENV_FILE" ] || {
  printf '%s\n' "Refusing to overwrite existing environment file: $ENV_FILE" >&2
  exit 1
}

umask 077
root_password=$(openssl rand -base64 48 | tr -d '\n')

printf '%s\n' \
  'MINIO_ROOT_USER=minio_cacto' \
  "MINIO_ROOT_PASSWORD=$root_password" \
  'MINIO_BROWSER_REDIRECT_URL=http://2.25.172.31:9001' \
  '' \
  'OBJECT_STORAGE_ENDPOINT=http://minio:9000' \
  'OBJECT_STORAGE_EXTERNAL_ENDPOINT=http://2.25.172.31:9000' \
  'OBJECT_STORAGE_REGION=us-east-1' \
  'OBJECT_STORAGE_SECURE=false' \
  '' \
  'OBJECT_STORAGE_LANDING_BUCKET=raio-x-landing-prod' \
  'OBJECT_STORAGE_LAKE_BUCKET=raio-x-lake-prod' \
  'OBJECT_STORAGE_ARTIFACTS_BUCKET=raio-x-artifacts-prod' > "$ENV_FILE"
chmod 600 "$ENV_FILE"

printf '%s\n' "Created protected environment file: $ENV_FILE"
