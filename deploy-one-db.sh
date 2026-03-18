#!/usr/bin/env bash
set -euo pipefail

# Deploy shared stack with one PostgreSQL instance and two databases (recipes + poetry).
# Run from web-folders repository root or pass WEB_FOLDERS_DIR.

WEB_FOLDERS_DIR="${WEB_FOLDERS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yaml}"

RECIPES_DB="${RECIPES_POSTGRES_DB:-recipes}"
RECIPES_USER="${RECIPES_POSTGRES_USER:-recipes_user}"
POETRY_DB="${POETRY_POSTGRES_DB:-poetry}"
POETRY_USER="${POETRY_POSTGRES_USER:-poetry_user}"
POETRY_PASSWORD="${POETRY_POSTGRES_PASSWORD:-change-me-poetry-db}"

RECIPES_HTTP_HOST="${RECIPES_PRIMARY_DOMAIN:-recipes.local}"
POETRY_HTTP_HOST="${POETRY_PRIMARY_DOMAIN:-poetry.local}"

compose() {
  if command -v docker-compose >/dev/null 2>&1; then
    docker-compose -f "$COMPOSE_FILE" "$@"
  else
    docker compose -f "$COMPOSE_FILE" "$@"
  fi
}

wait_for_pg() {
  local retries=30
  local delay=2

  echo "Waiting for PostgreSQL readiness..."
  for ((i=1; i<=retries; i++)); do
    if compose exec -T recipes-db pg_isready -U "$RECIPES_USER" -d "$RECIPES_DB" >/dev/null 2>&1; then
      echo "PostgreSQL is ready"
      return 0
    fi
    sleep "$delay"
  done

  echo "PostgreSQL did not become ready in time"
  return 1
}

ensure_poetry_db() {
  echo "Ensuring poetry role/database exist..."
  # Shell substitution in heredoc (no single-quotes around SQL) so that
  # $POETRY_USER / $POETRY_PASSWORD / $POETRY_DB are expanded by bash
  # before the SQL reaches psql.  We escape the password with printf to
  # neutralise any single-quotes it may contain.
  local escaped_pw
  escaped_pw=$(printf '%s' "$POETRY_PASSWORD" | sed "s/'/''/g")

  compose exec -T recipes-db psql -v ON_ERROR_STOP=1 \
    -U "$RECIPES_USER" -d "$RECIPES_DB" <<SQL
DO
\$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${POETRY_USER}') THEN
    EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L', '${POETRY_USER}', '${escaped_pw}');
  END IF;
END
\$\$;

SELECT format('CREATE DATABASE %I OWNER %I', '${POETRY_DB}', '${POETRY_USER}')
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${POETRY_DB}')\gexec

DO
\$\$
BEGIN
  EXECUTE format('GRANT ALL PRIVILEGES ON DATABASE %I TO %I', '${POETRY_DB}', '${POETRY_USER}');
END
\$\$;
SQL
}

wait_for_http_health() {
  local name="$1"
  local host_header="$2"
  local retries=60
  local delay=2

  echo "Waiting for ${name} health via nginx (Host: ${host_header})..."
  for ((i=1; i<=retries; i++)); do
    if curl -fsS -H "Host: ${host_header}" http://localhost/api/health >/dev/null 2>&1; then
      echo "${name} health check passed"
      return 0
    fi
    sleep "$delay"
  done

  echo "${name} health check failed after $((retries * delay))s"
  return 1
}

main() {
  cd "$WEB_FOLDERS_DIR"

  compose config >/dev/null

  compose up -d recipes-db
  wait_for_pg
  ensure_poetry_db

  echo "Building backend/frontend/nginx images..."
  compose build recipes-backend poetry-backend recipes-frontend nginx

  echo "Starting stack..."
  compose up -d --remove-orphans recipes-db recipes-backend poetry-backend recipes-frontend nginx certbot

  wait_for_http_health "recipes" "$RECIPES_HTTP_HOST"
  wait_for_http_health "poetry" "$POETRY_HTTP_HOST"

  compose ps
}

main "$@"
