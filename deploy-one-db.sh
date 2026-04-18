#!/usr/bin/env bash
# Deploy shared stack: one PostgreSQL + N apps as listed in sites.yaml.
# Loops the manifest via scripts/sites-lib.sh.
set -euo pipefail

WEB_FOLDERS_DIR="${WEB_FOLDERS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yaml}"

# shellcheck source=scripts/sites-lib.sh
. "$WEB_FOLDERS_DIR/scripts/sites-lib.sh"

# The "admin" Postgres role/DB (owns the cluster). Not in the manifest.
RECIPES_DB="${RECIPES_POSTGRES_DB:-recipes}"
RECIPES_USER="${RECIPES_POSTGRES_USER:-recipes_user}"

compose() {
  if command -v docker-compose >/dev/null 2>&1; then
    docker-compose -f "$COMPOSE_FILE" "$@"
  else
    docker compose -f "$COMPOSE_FILE" "$@"
  fi
}

wait_for_pg() {
  local retries=30 delay=2
  echo "Waiting for PostgreSQL readiness..."
  for ((i=1; i<=retries; i++)); do
    if compose exec -T recipes-db pg_isready -U "$RECIPES_USER" -d "$RECIPES_DB" >/dev/null 2>&1; then
      echo "PostgreSQL is ready"; return 0
    fi
    sleep "$delay"
  done
  echo "PostgreSQL did not become ready in time" >&2
  return 1
}

ensure_role_db() {
  local app_user="$1" app_password="$2" app_db="$3" escaped_pw
  escaped_pw=$(printf '%s' "$app_password" | sed "s/'/''/g")

  compose exec -T recipes-db psql -v ON_ERROR_STOP=1 \
    -U "$RECIPES_USER" -d "$RECIPES_DB" <<SQL
DO
\$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${app_user}') THEN
    EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L', '${app_user}', '${escaped_pw}');
  END IF;
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
  while IFS=$'\t' read -r id db_var user_var pwd_var; do
    local app_db="${!db_var:-}" app_user="${!user_var:-}" app_pw="${!pwd_var:-}"
    if [ -z "$app_db" ] || [ -z "$app_user" ] || [ -z "$app_pw" ]; then
      echo "WARN: site '$id' has incomplete DB vars ($db_var/$user_var/$pwd_var) -- skipping" >&2
      continue
    fi
    echo "Ensuring $id role/database exist..."
    ensure_role_db "$app_user" "$app_pw" "$app_db"
  done < <(sites_with_db)
}

# Generic: name, host_header, path
wait_for_health() {
  local name="$1" host_header="$2" path="$3"
  local retries=60 delay=2
  echo "Waiting for ${name} health via nginx (Host: ${host_header}${path})..."
  for ((i=1; i<=retries; i++)); do
    if curl -fsS -H "Host: ${host_header}" "http://localhost${path}" >/dev/null 2>&1; then
      echo "${name} health check passed"; return 0
    fi
    sleep "$delay"
  done
  echo "${name} health check failed after $((retries * delay))s" >&2
  return 1
}

# Collect compose service names from the manifest.
collect_app_services() {
  sites_compose_services
}

main() {
  cd "$WEB_FOLDERS_DIR"

  compose config >/dev/null

  compose up -d recipes-db
  wait_for_pg
  ensure_app_dbs

  # Build list of services to (build|up). Append the always-on infra services.
  local app_services=()
  while IFS= read -r s; do app_services+=("$s"); done < <(collect_app_services)
  local infra_services=(recipes-db nginx)
  local infra_only_up=(certbot)  # not built by us

  echo "Building backend/frontend/nginx images..."
  compose build "${app_services[@]}" "${infra_services[@]}"

  echo "Starting stack..."
  compose up -d --remove-orphans \
    "${infra_services[@]}" "${infra_only_up[@]}" "${app_services[@]}"

  # Force-recreate landing container so static updates are applied on every deploy.
  if printf '%s\n' "${app_services[@]}" | grep -qx mainpage-landing; then
    compose up -d --force-recreate mainpage-landing
  fi

  # Health-check every site that declares a health_path.
  while IFS=$'\t' read -r id host path; do
    wait_for_health "$id" "$host" "$path"
  done < <(sites_with_health)

  compose ps
}

main "$@"

