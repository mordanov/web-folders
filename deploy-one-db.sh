#!/usr/bin/env bash
set -euo pipefail

# Deploy shared stack with one PostgreSQL instance and three databases (recipes + poetry + news).
# Run from web-folders repository root or pass WEB_FOLDERS_DIR.

WEB_FOLDERS_DIR="${WEB_FOLDERS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yaml}"

RECIPES_DB="${RECIPES_POSTGRES_DB:-recipes}"
RECIPES_USER="${RECIPES_POSTGRES_USER:-recipes_user}"
POETRY_DB="${POETRY_POSTGRES_DB:-poetry}"
POETRY_USER="${POETRY_POSTGRES_USER:-poetry_user}"
POETRY_PASSWORD="${POETRY_POSTGRES_PASSWORD:-change-me-poetry-db}"
NEWS_DB="${NEWS_POSTGRES_DB:-news}"
NEWS_USER="${NEWS_POSTGRES_USER:-news_user}"
NEWS_PASSWORD="${NEWS_POSTGRES_PASSWORD:-change-me-news-db}"
BUDGET_DB="${BUDGET_POSTGRES_DB:-budget}"
BUDGET_USER="${BUDGET_POSTGRES_USER:-budget_user}"
BUDGET_PASSWORD="${BUDGET_POSTGRES_PASSWORD:-change-me-budget-db}"
REMINDERS_DB="${REMINDERS_POSTGRES_DB:-reminders}"
REMINDERS_USER="${REMINDERS_POSTGRES_USER:-reminders_user}"
REMINDERS_PASSWORD="${REMINDERS_POSTGRES_PASSWORD:-change-me-reminders-db}"
ARCHIVE_DB="${ARCHIVE_POSTGRES_DB:-archive}"
ARCHIVE_USER="${ARCHIVE_POSTGRES_USER:-archive_user}"
ARCHIVE_PASSWORD="${ARCHIVE_POSTGRES_PASSWORD:-change-me-archive-db}"

RECIPES_HTTP_HOST="${RECIPES_PRIMARY_DOMAIN:-recipes.local}"
POETRY_HTTP_HOST="${POETRY_PRIMARY_DOMAIN:-poetry.local}"
NEWS_HTTP_HOST="${NEWS_PRIMARY_DOMAIN:-news.mainpage.local}"
BUDGET_HTTP_HOST="${BUDGET_PRIMARY_DOMAIN:-budget.mainpage.local}"
REMINDERS_HTTP_HOST="${REMINDERS_PRIMARY_DOMAIN:-reminders.mainpage.local}"
ARCHIVE_HTTP_HOST="${ARCHIVE_PRIMARY_DOMAIN:-archive.mainpage.local}"

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

ensure_role_db() {
  local app_user="$1"
  local app_password="$2"
  local app_db="$3"
  local escaped_pw

  # Escape single quotes in SQL literal before passing to psql.
  escaped_pw=$(printf '%s' "$app_password" | sed "s/'/''/g")

  compose exec -T recipes-db psql -v ON_ERROR_STOP=1 \
    -U "$RECIPES_USER" -d "$RECIPES_DB" <<SQL
DO
\$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${app_user}') THEN
    EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L', '${app_user}', '${escaped_pw}');
  END IF;

  -- Keep role password in sync with current environment values.
  EXECUTE format('ALTER ROLE %I WITH LOGIN PASSWORD %L', '${app_user}', '${escaped_pw}');
END
\$\$;

SELECT format('CREATE DATABASE %I OWNER %I', '${app_db}', '${app_user}')
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${app_db}')\gexec

DO
\$\$
BEGIN
  EXECUTE format('ALTER DATABASE %I OWNER TO %I', '${app_db}', '${app_user}');
  EXECUTE format('GRANT ALL PRIVILEGES ON DATABASE %I TO %I', '${app_db}', '${app_user}');
END
\$\$;
SQL
}

ensure_app_dbs() {
  echo "Ensuring poetry role/database exist..."
  ensure_role_db "$POETRY_USER" "$POETRY_PASSWORD" "$POETRY_DB"

  echo "Ensuring news role/database exist..."
  ensure_role_db "$NEWS_USER" "$NEWS_PASSWORD" "$NEWS_DB"

  echo "Ensuring budget role/database exist..."
  ensure_role_db "$BUDGET_USER" "$BUDGET_PASSWORD" "$BUDGET_DB"

  echo "Ensuring reminders role/database exist..."
  ensure_role_db "$REMINDERS_USER" "$REMINDERS_PASSWORD" "$REMINDERS_DB"

  echo "Ensuring archive role/database exist..."
  ensure_role_db "$ARCHIVE_USER" "$ARCHIVE_PASSWORD" "$ARCHIVE_DB"
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

wait_for_budget_health() {
  local name="$1"
  local host_header="$2"
  local retries=60
  local delay=2

  echo "Waiting for ${name} health via nginx (Host: ${host_header})..."
  for ((i=1; i<=retries; i++)); do
    if curl -fsS -H "Host: ${host_header}" http://localhost/health >/dev/null 2>&1; then
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
  ensure_app_dbs

  echo "Building backend/frontend/nginx images..."
  compose build recipes-backend poetry-backend news-backend recipes-frontend news-frontend mainpage-landing budget-backend budget-frontend reminders-backend reminders-frontend archive-backend archive-frontend nginx

  echo "Starting stack..."
  compose up -d --remove-orphans recipes-db recipes-backend poetry-backend news-backend recipes-frontend news-frontend mainpage-landing budget-backend budget-frontend reminders-backend reminders-frontend archive-backend archive-frontend nginx certbot

  # Force-recreate landing container so static web-folders updates are applied on every deploy.
  compose up -d --force-recreate mainpage-landing

  wait_for_http_health "recipes" "$RECIPES_HTTP_HOST"
  wait_for_http_health "poetry" "$POETRY_HTTP_HOST"
  wait_for_http_health "news" "$NEWS_HTTP_HOST"
  wait_for_budget_health "budget" "$BUDGET_HTTP_HOST"
  wait_for_budget_health "reminders" "$REMINDERS_HTTP_HOST"
  wait_for_budget_health "archive" "$ARCHIVE_HTTP_HOST"

  compose ps
}

main "$@"
