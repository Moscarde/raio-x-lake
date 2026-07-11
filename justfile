set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

compose := "docker compose -f docker-compose.minio.yml"
data_dir := "/srv/raio-x/minio/data"

default:
  @just --list

# Create the Docker network shared with the separate Astro deployment.
network:
  @docker network inspect raio-x-data >/dev/null 2>&1 || docker network create raio-x-data

# Generate root credentials locally on the VPS only once.
init:
  @if [ ! -f .env ]; then ./scripts/initialize-minio-env.sh; fi

# Start MinIO and create its buckets, policies, and application users.
up: network init
  {{compose}} up -d
  ./scripts/bootstrap-minio.sh

# Stop MinIO without removing persisted objects.
down:
  {{compose}} down

# Delete all MinIO data. Invoke only as: just reset DELETE-MINIO-DATA
reset confirm='':
  @test "{{confirm}}" = "DELETE-MINIO-DATA" || { printf '%s\n' 'Refusing reset. Run: just reset DELETE-MINIO-DATA' >&2; exit 1; }
  {{compose}} down --remove-orphans
  sudo rm -rf {{data_dir}}
  sudo install -d -m 0700 {{data_dir}}
  rm -f .minio.application.env

# Show the MinIO container state and current healthcheck status.
status:
  {{compose}} ps
