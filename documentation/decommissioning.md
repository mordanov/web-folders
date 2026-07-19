# Application Decommissioning from web-folders

You are fully removing an application from the shared `web-folders` infrastructure. This is irreversible past the backup step. Work through every phase in order and confirm the backup exists before proceeding to deletion.

---

## 0. Gather facts before starting

Establish the following facts about the application being decommissioned.

| Fact | Where to find it |
|---|---|
| `APP_ID` | The kebab-case `id` field in `sites.yaml` |
| `APP_PREFIX` | The SCREAMING_SNAKE env var prefix used in `.env` and `docker-compose.yaml` |
| Service names | `compose_services` field in `sites.yaml` |
| DB name | `${APP_PREFIX}_POSTGRES_DB` in `.env` |
| DB user | `${APP_PREFIX}_POSTGRES_USER` in `.env` |
| Redis service | Does the app have a dedicated `<APP_ID>-redis` service? |
| GHCR image names | `image:` values in `docker-compose.yaml` for this app |
| Mainpage toggle | `MAINPAGE_ENABLE_<KEY>` in `.env.example` and `mainpage-landing.environment` |

---

## Phase 1 — Back up the database

**This phase is mandatory. Do not proceed to Phase 2 until the backup file exists and is non-empty.**

### 1a. SSH to the VPS

```bash
ssh <VPS_USER>@<VPS_HOST>
cd /home/deploy/web-folders
```

### 1b. Load environment variables

```bash
set -a && . .env && set +a
```

### 1c. Create the backup

```bash
BACKUP_DIR="./backups"
BACKUP_FILE="$BACKUP_DIR/<APP_ID>-$(date +%Y%m%d-%H%M%S).sql.gz"
mkdir -p "$BACKUP_DIR"

docker compose exec -e PGPASSWORD="$RECIPES_POSTGRES_PASSWORD" recipes-db \
  pg_dump \
    -U "$RECIPES_POSTGRES_USER" \
    -d "${<APP_PREFIX>_POSTGRES_DB}" \
    --no-owner --no-acl \
  | gzip > "$BACKUP_FILE"
```

### 1d. Verify the backup

```bash
# Must report a non-zero size
ls -lh "$BACKUP_FILE"

# Must produce output without errors (shows CREATE TABLE statements, etc.)
zcat "$BACKUP_FILE" | head -40
```

Do not continue until both checks pass.

### 1e. Copy the backup off the VPS

```bash
# From your local machine:
scp <VPS_USER>@<VPS_HOST>:/home/deploy/web-folders/backups/<APP_ID>-*.sql.gz ./
```

Keep the backup for at least 30 days before deleting it.

---

## Phase 2 — Stop and remove containers

### 2a. Stop the application services

```bash
cd /home/deploy/web-folders
docker compose stop \
  <APP_ID>-backend \
  <APP_ID>-worker \    # if exists
  <APP_ID>-frontend \
  <APP_ID>-redis       # if exists
```

### 2b. Remove the stopped containers

```bash
docker compose rm -f \
  <APP_ID>-backend \
  <APP_ID>-worker \    # if exists
  <APP_ID>-frontend \
  <APP_ID>-redis       # if exists
```

### 2c. Confirm no containers remain

```bash
docker compose ps --all | grep <APP_ID>
# Expected: no output
```

---

## Phase 3 — Drop the database and role

**Double-check you are working against the correct database name before running DROP.**

```bash
cd /home/deploy/web-folders

DB_NAME="${<APP_PREFIX>_POSTGRES_DB}"
DB_USER="${<APP_PREFIX>_POSTGRES_USER}"
ADMIN_DB="${RECIPES_POSTGRES_DB:-recipes}"
ADMIN_USER="${RECIPES_POSTGRES_USER:-recipes_user}"

docker compose exec \
  -e PGPASSWORD="$RECIPES_POSTGRES_PASSWORD" \
  recipes-db \
  psql -U "$ADMIN_USER" -d "$ADMIN_DB" <<SQL
-- Terminate any remaining connections to the database
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = '$DB_NAME' AND pid <> pg_backend_pid();

DROP DATABASE IF EXISTS "$DB_NAME";
DROP ROLE IF EXISTS "$DB_USER";
SQL
```

Confirm:

```bash
docker compose exec \
  -e PGPASSWORD="$RECIPES_POSTGRES_PASSWORD" \
  recipes-db \
  psql -U "$RECIPES_POSTGRES_USER" -d "$RECIPES_POSTGRES_DB" \
  -c "\l $DB_NAME"
# Expected: no rows returned (database is gone)
```

---

## Phase 4 — Remove from `docker-compose.yaml`

File: `web-folders/docker-compose.yaml`

Make four changes.

### 4a. Remove the service definitions

Delete the entire service blocks for:
- `<APP_ID>-backend:`
- `<APP_ID>-worker:` (if exists)
- `<APP_ID>-frontend:`
- `<APP_ID>-redis:` (if exists)

### 4b. Remove Postgres env vars from `recipes-db`

Delete from `recipes-db.environment:`:
```yaml
      <APP_PREFIX>_POSTGRES_DB: ...
      <APP_PREFIX>_POSTGRES_USER: ...
      <APP_PREFIX>_POSTGRES_PASSWORD: ...
```

### 4c. Remove Postgres env vars from `db-password-sync`

Delete the same three lines from `db-password-sync.environment:`.

### 4d. Remove from `nginx`

Delete from `nginx.environment:`:
```yaml
      <APP_PREFIX>_PRIMARY_DOMAIN: ...
      <APP_PREFIX>_SERVER_NAMES: ...
```

Delete from `nginx.depends_on:`:
```yaml
      - <APP_ID>-backend
      - <APP_ID>-worker
      - <APP_ID>-frontend
```

---

## Phase 5 — Remove from `sites.yaml`

File: `web-folders/sites.yaml`

Delete the entire entry block for `id: <APP_ID>`.

---

## Phase 6 — Remove nginx templates

```bash
rm web-folders/nginx/templates/<APP_ID>-http.conf.template
rm web-folders/nginx/templates/<APP_ID>-http-redirect.conf.template
rm web-folders/nginx/templates/<APP_ID>-https.conf.template
```

---

## Phase 7 — Update `.env.example`

File: `web-folders/.env.example`

Delete the entire `# --- <APP_ID> ---` section, including all its vars.

Also delete the mainpage toggle line if present:
```dotenv
MAINPAGE_ENABLE_<KEY>=1
```

---

## Phase 8 — Update `docker-compose.yaml` — mainpage landing

If the app had a mainpage link, delete from `mainpage-landing.environment:`:
```yaml
      MAINPAGE_ENABLE_<KEY>: ...
```

---

## Phase 9 — Remove from `.env` on the VPS

SSH to the VPS and manually edit `.env` to remove the `<APP_PREFIX>_*` block for this app. Do not remove any vars belonging to other apps.

```bash
ssh <VPS_USER>@<VPS_HOST>
cd /home/deploy/web-folders
# Edit .env and remove the <APP_ID> section
```

---

## Phase 10 — Remove the CI workflow template

```bash
rm web-folders/ci-workflow-templates/<APP_ID>.yml
```

Remove the corresponding row from `ci-workflow-templates/README.md`.

In the application's own GitHub repository, delete (or disable) the workflow file `.github/workflows/build-deploy.yml`.

---

## Phase 11 — Deprecate and delete GHCR images

GHCR images are not deleted automatically when containers are removed. Deprecate each image package through the GitHub UI or CLI.

### Via GitHub web UI

For each image (`ghcr.io/mordanov/<APP_ID>-backend`, `ghcr.io/mordanov/<APP_ID>-frontend`, etc.):

1. Go to **github.com/mordanov → Packages**
2. Open the package
3. Click **Package settings**
4. Scroll to **Danger Zone** → **Delete this package**

### Via GitHub CLI

```bash
# List all versions of the package
gh api /user/packages/container/<APP_ID>-backend/versions \
  --jq '.[].id'

# Delete each version
gh api --method DELETE /user/packages/container/<APP_ID>-backend/versions/<VERSION_ID>

# Or delete the entire package if all versions should go
gh api --method DELETE /user/packages/container/<APP_ID>-backend
```

Repeat for each image (backend, worker, frontend, etc.).

---

## Phase 12 — Restart the stack and verify

On the VPS:

```bash
cd /home/deploy/web-folders

# Apply the compose changes — removes any remaining containers and reloads nginx
docker compose up -d

# Nginx config must be valid (no references to the removed app remain)
docker compose exec nginx nginx -t

# Confirm no <APP_ID> containers or volumes remain
docker compose ps --all | grep <APP_ID>   # expected: no output
docker volume ls | grep <APP_ID>           # expected: no output (no named volumes)
```

Confirm the domain now returns a 404 or connection refused — it must not serve the old application.

```bash
curl -sI https://<PRIMARY_DOMAIN>
# Expected: connection refused, or nginx default 404
```

---

## Checklist

- [ ] Database backup created, verified non-empty, and copied off the VPS
- [ ] Containers stopped and removed
- [ ] Database dropped from `recipes-db`
- [ ] DB role dropped from `recipes-db`
- [ ] Service definitions removed from `docker-compose.yaml`
- [ ] Postgres env vars removed from `recipes-db` and `db-password-sync`
- [ ] Domain env vars removed from `nginx.environment`
- [ ] Services removed from `nginx.depends_on`
- [ ] Entry removed from `sites.yaml`
- [ ] Three nginx templates deleted
- [ ] App section removed from `.env.example`
- [ ] Mainpage toggle removed from `.env.example` and `docker-compose.yaml`
- [ ] App vars removed from `.env` on the VPS
- [ ] CI workflow template deleted from `web-folders/ci-workflow-templates/`
- [ ] CI workflow template row removed from `ci-workflow-templates/README.md`
- [ ] Workflow disabled or deleted in the app's GitHub repository
- [ ] All GHCR image packages deleted
- [ ] Stack restarted, `nginx -t` passes
- [ ] Domain no longer serves the application
