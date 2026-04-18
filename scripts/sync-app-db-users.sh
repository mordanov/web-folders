#!/bin/sh
# scripts/sync-app-db-users.sh — runs inside the db-password-sync container
# (postgres:16-alpine) at every `compose up` to ensure each per-site role and
# database exists with the password from the current environment.
#
# Site list is read from /etc/web-folders/sites.yaml (bind-mounted by compose).
set -eu

DB_HOST="recipes-db"
DB_PORT="5432"
ADMIN_DB="${RECIPES_POSTGRES_DB:-recipes}"
ADMIN_USER="${RECIPES_POSTGRES_USER:-recipes_user}"
ADMIN_PASSWORD="${RECIPES_POSTGRES_PASSWORD:-change-me-recipes-db}"
SITES_YAML="${SITES_YAML:-/etc/web-folders/sites.yaml}"

export PGPASSWORD="$ADMIN_PASSWORD"

# Install yq once (alpine community repo, single binary).
if ! command -v yq >/dev/null 2>&1; then
  apk add --no-cache yq >/dev/null
fi

if [ ! -f "$SITES_YAML" ]; then
  echo "FATAL: sites manifest not found at $SITES_YAML" >&2
  exit 1
fi

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

# POSIX-compatible indirect expansion.
get_env() {
  eval "printf '%s' \"\${$1-}\""
}

wait_for_pg

# Loop manifest sites that declare a `db` block.
yq -r '.sites[] | select(.db) | [.id, .db.db_var, .db.user_var, .db.password_var] | @tsv' "$SITES_YAML" \
| while IFS="$(printf '\t')" read -r id db_var user_var pwd_var; do
    app_db=$(get_env "$db_var")
    app_user=$(get_env "$user_var")
    app_pw=$(get_env "$pwd_var")
    if [ -z "$app_db" ] || [ -z "$app_user" ] || [ -z "$app_pw" ]; then
      echo "WARN: site '$id' has incomplete DB env vars (${db_var}/${user_var}/${pwd_var}) -- skipping" >&2
      continue
    fi
    echo "Syncing role/db for site '$id'..."
    sync_role_db "$app_user" "$app_pw" "$app_db"
  done

