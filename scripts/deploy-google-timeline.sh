#!/usr/bin/env bash
# scripts/deploy-google-timeline.sh
#
# Manual first-time deployment of google-timeline services on the VPS.
# Pulls images directly (bypassing pull_policy: never in docker-compose.yaml),
# creates the DB role/database if needed, and starts the containers.
#
# Prerequisites:
#   - docker login ghcr.io already done (see ci-workflow-templates/README.md)
#   - .env has GOOGLE_TIMELINE_* vars set
#
# Usage (from web-folders directory):
#   bash scripts/deploy-google-timeline.sh
#
# After this script succeeds, CI deployments take over automatically —
# no further changes needed.
set -euo pipefail

WEB_FOLDERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$WEB_FOLDERS_DIR"

ENV_FILE="${ENV_FILE:-$WEB_FOLDERS_DIR/.env}"
if [ -f "$ENV_FILE" ]; then
  set -a
  set +u
  . "$ENV_FILE"
  set -u
  set +a
fi

compose() {
  docker compose --env-file "$ENV_FILE" -f docker-compose.yaml "$@"
}

echo "=== google-timeline manual deployment ==="

# 1. Pull images directly — bypasses pull_policy: never in compose file.
echo ""
echo "--- Pulling images from ghcr.io ---"
docker pull ghcr.io/mordanov/google-timeline-backend:latest
docker pull ghcr.io/mordanov/google-timeline-importer:latest
docker pull ghcr.io/mordanov/google-timeline-frontend:latest
echo "Images pulled successfully."

# 2. Ensure postgres is up.
echo ""
echo "--- Waiting for PostgreSQL ---"
compose up -d recipes-db
until compose exec -T recipes-db \
    pg_isready \
    -U "${RECIPES_POSTGRES_USER:-recipes_user}" \
    -d "${RECIPES_POSTGRES_DB:-recipes}" >/dev/null 2>&1; do
  sleep 2
done
echo "PostgreSQL ready."

# 3. Create DB role and database if they don't exist.
echo ""
echo "--- Ensuring database role and database ---"
PGPASSWORD="${RECIPES_POSTGRES_PASSWORD}" \
compose exec -T \
  -e PGPASSWORD="${RECIPES_POSTGRES_PASSWORD}" \
  recipes-db \
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
echo "Database ready."

# 4. Start the three services using the locally cached images.
echo ""
echo "--- Starting services ---"
compose up -d --no-deps \
  google-timeline-backend \
  google-timeline-importer \
  google-timeline-frontend

# 5. Reload nginx so the new vhost is picked up.
echo ""
echo "--- Reloading nginx ---"
compose exec -T nginx nginx -s reload || true

echo ""
echo "--- Status ---"
compose ps google-timeline-backend google-timeline-importer google-timeline-frontend

echo ""
echo "Done."
echo "Once verified, CI deployments (GitHub Actions) will handle future updates automatically."
