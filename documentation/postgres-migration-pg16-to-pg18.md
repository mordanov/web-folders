# PostgreSQL Migration: PG16 → PG18 + Merge reminders2-db

## Overview

Current state:
- `recipes-db` — `postgis/postgis:16-3.4`, holds all app databases
- `reminders2-db` — `postgres:18-alpine`, separate instance for reminders2 only

Target state:
- Single `recipes-db` — `postgis/postgis:18-3.5`, all databases including reminders2

**This is a breaking migration. Do it during a maintenance window. All services will be
briefly unavailable. Data loss is unacceptable — follow every step in order.**

---

## Phase 1: Migrate reminders2 into the main DB

### 1.1 Dump reminders2 data

```bash
docker exec web-folders-reminders2-db-1 \
  pg_dump -U reminders2_user reminders2 -F c \
  > /tmp/reminders2_$(date +%Y%m%d_%H%M%S).dump
```

### 1.2 Stop reminders2 services

```bash
docker compose stop reminders2-backend reminders2-frontend
```

### 1.3 Create reminders2 role and database in recipes-db

```bash
# Get the password from your .env
REMINDERS2_PW=$(grep REMINDERS2_POSTGRES_PASSWORD .env | cut -d= -f2)

docker exec -i web-folders-recipes-db-1 psql -U recipes_user <<SQL
CREATE USER reminders2_user WITH PASSWORD '${REMINDERS2_PW}';
CREATE DATABASE reminders2 OWNER reminders2_user;
GRANT ALL PRIVILEGES ON DATABASE reminders2 TO reminders2_user;
SQL
```

### 1.4 Restore the dump into recipes-db

```bash
DUMP_FILE=/tmp/reminders2_<timestamp>.dump   # use the file from 1.1

docker exec -i web-folders-recipes-db-1 \
  pg_restore -U reminders2_user -d reminders2 -F c < "$DUMP_FILE"
```

### 1.5 Deploy the new compose and verify

The compose changes are committed: `reminders2-backend` now points to `recipes-db`,
`reminders2-db` service is removed, and `sites.yaml` has the `db:` block for reminders2
(so `db-password-sync` will manage the role/DB going forward).

Pull and redeploy:

```bash
git pull
docker compose up -d reminders2-backend reminders2-frontend
```

Verify reminders2 works. Then remove the now-unused old container and volume:

```bash
docker compose rm -sf reminders2-db   # no-op if already stopped by compose up
docker volume rm web-folders_reminders2_postgres_data
```

---

## Phase 2: Upgrade recipes-db from PG16 to PG18

**Do this after Phase 1 is complete and verified.**

### 2.1 Full pg_dumpall backup

```bash
docker exec web-folders-recipes-db-1 \
  pg_dumpall -U recipes_user \
  > /tmp/pg16_full_$(date +%Y%m%d_%H%M%S).sql

# Verify it's not empty
wc -l /tmp/pg16_full_*.sql
```

**Keep this backup file safe.** Copy it off the server before proceeding.

### 2.2 Stop all application services (keep only recipes-db running)

```bash
docker compose stop \
  recipes-backend recipes-frontend \
  poetry-backend \
  news-backend news-frontend \
  budget-backend budget-frontend \
  reminders-backend reminders-frontend \
  admin-routine-backend admin-routine-frontend \
  archive-backend archive-frontend \
  portuguese-expenses-backend portuguese-expenses-frontend \
  label-system-backend label-system-frontend \
  home-resources-backend home-resources-frontend \
  google-timeline-backend google-timeline-importer google-timeline-frontend \
  doc-forge-backend doc-forge-frontend \
  reminders2-backend reminders2-frontend \
  fuel-weather-bot flying-search-bot \
  nginx certbot pgview
```

### 2.3 Stop and remove recipes-db

```bash
docker compose stop recipes-db
docker compose rm -f recipes-db
```

### 2.4 Rename the old data volume (safety backup)

```bash
# Create a temporary container to copy the volume data
docker run --rm \
  -v web-folders_recipes_postgres_data:/source:ro \
  -v web-folders_recipes_postgres_data_pg16_backup:/dest \
  alpine sh -c "cp -a /source/. /dest/"
```

### 2.5 Update docker-compose.yaml — change the image

Edit `docker-compose.yaml`, change:
```yaml
  recipes-db:
    image: postgis/postgis:16-3.4
```
to:
```yaml
  recipes-db:
    image: postgis/postgis:18-3.5
```

(The `reminders2-db` service and volume were already removed in Phase 1.)

### 2.6 Clear the old data directory and start fresh PG18

The PG16 data directory is binary-incompatible with PG18 and must be removed:

```bash
# Remove old data volume content (the pg16_backup volume is your safety net)
docker volume rm web-folders_recipes_postgres_data
docker volume create web-folders_recipes_postgres_data

# Start PG18 with empty data
docker compose up -d recipes-db
# Wait for it to initialize (watch logs)
docker compose logs -f recipes-db
```

Wait until you see: `database system is ready to accept connections`

### 2.7 Restore all databases

```bash
DUMP_FILE=/tmp/pg16_full_<timestamp>.sql

docker exec -i web-folders-recipes-db-1 \
  psql -U recipes_user postgres < "$DUMP_FILE"
```

Check for errors in the output. PostGIS extension DDL warnings are normal.

### 2.8 Start all services

```bash
docker compose up -d
docker compose ps
docker compose logs --tail=50
```

### 2.9 Verify

- Check each app's health endpoint
- Verify data integrity (spot-check a few records in each DB)
- Monitor logs for 10–15 minutes

### 2.10 Cleanup (only after verification)

```bash
# Remove the pg16 backup volume (ONLY when you're confident everything works)
docker volume rm web-folders_recipes_postgres_data_pg16_backup
```

---

## Rollback plan

If anything fails in Phase 2:

```bash
# Stop PG18
docker compose stop recipes-db
docker compose rm -f recipes-db

# Restore PG16 image in docker-compose.yaml
# Restore data volume from backup
docker volume rm web-folders_recipes_postgres_data
docker run --rm \
  -v web-folders_recipes_postgres_data_pg16_backup:/source:ro \
  -v web-folders_recipes_postgres_data:/dest \
  alpine sh -c "cp -a /source/. /dest/"

# Start PG16
docker compose up -d recipes-db
docker compose up -d
```
