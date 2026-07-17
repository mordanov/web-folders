#!/usr/bin/env bash
# scripts/decommission-ticket-manager.sh
#
# Backs up, then stops and removes ticket-manager containers and drops the
# Postgres database and role from the shared recipes-db instance.
#
# Run from the web-folders directory with the .env already loaded:
#   cd /path/to/web-folders
#   set -a && . .env && set +a
#   bash scripts/decommission-ticket-manager.sh
#
# Requires: docker compose v2
set -euo pipefail

DB_NAME="${TICKET_MANAGER_POSTGRES_DB:-ticket_manager}"
DB_USER="${TICKET_MANAGER_POSTGRES_USER:-ticket_manager_user}"
ADMIN_DB="${RECIPES_POSTGRES_DB:-recipes}"
ADMIN_USER="${RECIPES_POSTGRES_USER:-recipes_user}"
ADMIN_PASSWORD="${RECIPES_POSTGRES_PASSWORD:-change-me-recipes-db}"

BACKUP_DIR="${BACKUP_DIR:-./backups}"
BACKUP_FILE="$BACKUP_DIR/ticket-manager-$(date +%Y%m%d-%H%M%S).sql.gz"

echo "=== ticket-manager decommission ==="
echo "  DB         : $DB_NAME"
echo "  Role       : $DB_USER"
echo "  Backup to  : $BACKUP_FILE"
echo ""
read -rp "Continue? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# 1. Backup
echo ""
echo "--- Backing up '$DB_NAME' ---"
mkdir -p "$BACKUP_DIR"
docker compose exec -e PGPASSWORD="$ADMIN_PASSWORD" recipes-db \
  pg_dump -U "$ADMIN_USER" -d "$DB_NAME" --no-owner --no-acl \
  | gzip > "$BACKUP_FILE"
echo "Backup written to $BACKUP_FILE ($(du -sh "$BACKUP_FILE" | cut -f1))"

# 2. Stop and remove containers
echo ""
echo "--- Stopping and removing containers ---"
docker compose stop ticket-manager-backend ticket-manager-frontend 2>/dev/null || true
docker compose rm -f ticket-manager-backend ticket-manager-frontend 2>/dev/null || true

# 3. Drop database and role
echo ""
echo "--- Dropping database '$DB_NAME' and role '$DB_USER' ---"
docker compose exec -e PGPASSWORD="$ADMIN_PASSWORD" recipes-db \
  psql -U "$ADMIN_USER" -d "$ADMIN_DB" <<SQL
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = '$DB_NAME' AND pid <> pg_backend_pid();

DROP DATABASE IF EXISTS "$DB_NAME";
DROP ROLE IF EXISTS "$DB_USER";
SQL

echo ""
echo "Done. Backup: $BACKUP_FILE"
