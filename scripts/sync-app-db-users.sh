#!/bin/sh
set -eu

DB_HOST="recipes-db"
DB_PORT="5432"
ADMIN_DB="${RECIPES_POSTGRES_DB:-recipes}"
ADMIN_USER="${RECIPES_POSTGRES_USER:-recipes_user}"
ADMIN_PASSWORD="${RECIPES_POSTGRES_PASSWORD:-change-me-recipes-db}"

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

export PGPASSWORD="$ADMIN_PASSWORD"

wait_for_pg() {
  retries=30
  while [ "$retries" -gt 0 ]; do
    if pg_isready -h "$DB_HOST" -p "$DB_PORT" -U "$ADMIN_USER" -d "$ADMIN_DB" >/dev/null 2>&1; then
      return 0
    fi
    retries=$((retries - 1))
    sleep 2
  done

  echo "PostgreSQL is not ready for password sync" >&2
  exit 1
}

sync_role_db() {
  app_user="$1"
  app_password="$2"
  app_db="$3"

  psql -v ON_ERROR_STOP=1 \
    -h "$DB_HOST" -p "$DB_PORT" -U "$ADMIN_USER" -d "$ADMIN_DB" <<SQL
DO
\$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${app_user}') THEN
    EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L', '${app_user}', '${app_password}');
  END IF;

  EXECUTE format('ALTER ROLE %I WITH LOGIN PASSWORD %L', '${app_user}', '${app_password}');
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

wait_for_pg
sync_role_db "$POETRY_USER" "$POETRY_PASSWORD" "$POETRY_DB"
sync_role_db "$NEWS_USER" "$NEWS_PASSWORD" "$NEWS_DB"
sync_role_db "$BUDGET_USER" "$BUDGET_PASSWORD" "$BUDGET_DB"
sync_role_db "$REMINDERS_USER" "$REMINDERS_PASSWORD" "$REMINDERS_DB"

