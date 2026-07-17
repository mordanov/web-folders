#!/usr/bin/env bash
# scripts/deploy-google-timeline.sh
#
# Run on the VPS to do a full first-time (or recovery) deployment of
# google-timeline services: pulls images, starts containers, runs migrations.
#
# Prerequisites:
#   - docker login ghcr.io already done (see ci-workflow-templates/README.md)
#   - .env in the web-folders directory has GOOGLE_TIMELINE_* vars set
#
# Usage (from web-folders directory):
#   bash scripts/deploy-google-timeline.sh
set -euo pipefail

WEB_FOLDERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$WEB_FOLDERS_DIR"

ENV_FILE="${ENV_FILE:-$WEB_FOLDERS_DIR/.env}"
if [ -f "$ENV_FILE" ]; then
  set -a; . "$ENV_FILE"; set +a
fi

compose() {
  docker compose --env-file "$ENV_FILE" -f docker-compose.yaml "$@"
}

echo "=== google-timeline deployment ==="

# 1. Remove pull_policy: never override so images are actually pulled.
#    The sed is a no-op if already removed.
echo ""
echo "--- Pulling images ---"
docker pull ghcr.io/mordanov/google-timeline-backend:latest
docker pull ghcr.io/mordanov/google-timeline-importer:latest
docker pull ghcr.io/mordanov/google-timeline-frontend:latest

# 2. Remove pull_policy: never from docker-compose.yaml now that images exist.
if grep -q "pull_policy: never" docker-compose.yaml; then
  echo ""
  echo "--- Removing pull_policy: never from docker-compose.yaml ---"
  # Remove the three pull_policy lines (one per google-timeline service)
  sed -i '/^  google-timeline-/,/^  [^ ]/{/pull_policy: never/d}' docker-compose.yaml
  echo "Done. Committing the change..."
  git add docker-compose.yaml
  git commit -m "fix: remove pull_policy: never now that google-timeline images are published"
  git push
fi

# 3. Ensure the DB role and database exist.
echo ""
echo "--- Ensuring database and role ---"
compose up -d recipes-db
echo "Waiting for PostgreSQL..."
until compose exec -T recipes-db pg_isready \
    -U "${RECIPES_POSTGRES_USER:-recipes_user}" \
    -d "${RECIPES_POSTGRES_DB:-recipes}" >/dev/null 2>&1; do
  sleep 2
done

PGPASSWORD="${RECIPES_POSTGRES_PASSWORD:-change-me-recipes-db}" \
compose exec -T recipes-db \
  psql -U "${RECIPES_POSTGRES_USER:-recipes_user}" \
       -d "${RECIPES_POSTGRES_DB:-recipes}" <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${GOOGLE_TIMELINE_POSTGRES_USER:-google_timeline_user}') THEN
    EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L',
      '${GOOGLE_TIMELINE_POSTGRES_USER:-google_timeline_user}',
      '${GOOGLE_TIMELINE_POSTGRES_PASSWORD:-change-me-google-timeline-db}');
  END IF;
  EXECUTE format('ALTER ROLE %I WITH LOGIN PASSWORD %L',
    '${GOOGLE_TIMELINE_POSTGRES_USER:-google_timeline_user}',
    '${GOOGLE_TIMELINE_POSTGRES_PASSWORD:-change-me-google-timeline-db}');
END\$\$;

SELECT format('CREATE DATABASE %I OWNER %I',
  '${GOOGLE_TIMELINE_POSTGRES_DB:-google_timeline}',
  '${GOOGLE_TIMELINE_POSTGRES_USER:-google_timeline_user}')
WHERE NOT EXISTS (
  SELECT FROM pg_database WHERE datname = '${GOOGLE_TIMELINE_POSTGRES_DB:-google_timeline}'
)\gexec
SQL

# 4. Start services.
echo ""
echo "--- Starting google-timeline services ---"
compose up -d --no-deps \
  google-timeline-backend \
  google-timeline-importer \
  google-timeline-frontend

echo ""
echo "--- Reloading nginx ---"
compose exec -T nginx nginx -s reload || true

echo ""
echo "Done. Services running:"
compose ps google-timeline-backend google-timeline-importer google-timeline-frontend
