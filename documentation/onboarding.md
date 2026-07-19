# Application Onboarding to web-folders

You are integrating a new application into the shared `web-folders` infrastructure on the VPS. This infrastructure runs a single Docker Compose stack with a shared nginx reverse proxy, a shared PostgreSQL instance (`recipes-db`), and a shared certbot for TLS certificates.

Follow every step below in order. Do not skip any step, even if it seems optional for the specific app.

---

## 0. Gather facts before starting

Before touching any file, establish the following facts about the application being onboarded. Read the app's own `docker-compose.yml`, `.env.example`, and nginx config to answer every question.

| Fact | Where to find it | Example |
|---|---|---|
| `APP_ID` | Kebab-case name, used as file prefix | `travelsearch` |
| `APP_PREFIX` | SCREAMING_SNAKE prefix for all env vars | `TRAVELSEARCH` |
| `PRIMARY_DOMAIN` | The cert-primary domain (one hostname) | `travelsearch.mainpage.com` |
| `SERVER_NAMES` | Full nginx `server_name` value (space-separated) | `travelsearch.mainpage.com` |
| Services | List of backend / worker / frontend service names | `travelsearch-backend`, `travelsearch-worker`, `travelsearch-frontend` |
| DB needed? | Does the app have its own Postgres database? | yes / no |
| DB name, user, password var names | From the app's own compose/env | `travelsearch`, `travelsearch_user`, `TRAVELSEARCH_POSTGRES_PASSWORD` |
| Redis needed? | Does the app use Redis (e.g. arq job queue)? | yes / no |
| Backend port | The port the backend listens on | `8000` |
| Backend `/api/` prefix? | Does nginx rewrite `/api/` → `/`? | yes (rewrite) / no (pass-through) |
| Extra locations | Telegram webhook, WebSocket, etc. | `/telegram/webhook` |
| `proxy_read_timeout` | Long if Playwright/scraping, short otherwise | `200s` / `60s` |
| Health check path | Used by `deploy-one-db.sh` | `/api/v1/health` |
| Mainpage link key | Key in `mainpage-landing/start.sh` link map | `TRAVELSEARCH` |
| VITE_ build args | Any env vars baked into the frontend at build time | `VITE_API_BASE_URL` |
| Priority | Integer controlling nginx template render order; pick the next available slot after the highest existing priority | `150` |
| GHCR image names | `ghcr.io/mordanov/<name>:latest` per service | `ghcr.io/mordanov/travelsearch-backend:latest` |

---

## 1. Add an entry to `sites.yaml`

File: `web-folders/sites.yaml`

Append a new entry to the `sites:` list. Choose a `priority` value that is higher than the current highest (use increments of 10).

```yaml
  - id: <APP_ID>
    priority: <PRIORITY>
    cert_label: <APP_ID>
    domain:
      primary_var: <APP_PREFIX>_PRIMARY_DOMAIN
      server_names_var: <APP_PREFIX>_SERVER_NAMES
    db:                                    # omit this block if app has no DB
      db_var: <APP_PREFIX>_POSTGRES_DB
      user_var: <APP_PREFIX>_POSTGRES_USER
      password_var: <APP_PREFIX>_POSTGRES_PASSWORD
    health_path: /api/v1/health            # adjust or omit if unused
    compose_services: [<APP_ID>-backend, <APP_ID>-worker, <APP_ID>-frontend]
```

`compose_services` is used by `deploy-one-db.sh` and CI debug dumps. List every Docker Compose service name that belongs to this app.

---

## 2. Create three nginx templates

Directory: `web-folders/nginx/templates/`

Create exactly three files. Use the google-timeline templates as the canonical reference.

### `<APP_ID>-http.conf.template`

HTTP-only mode, active before the TLS certificate is issued. Must include the ACME challenge location.

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name ${<APP_PREFIX>_SERVER_NAMES};

    # ACME challenge for certbot
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location /api/ {
        set $<app_id_underscored>_backend http://<APP_ID>-backend:<PORT>;
        proxy_pass $<app_id_underscored>_backend;
        include /etc/nginx/snippets/proxy-common.conf;
        proxy_read_timeout <TIMEOUT>;
    }

    # Add extra locations here (e.g. /telegram/webhook → backend).

    location / {
        set $<app_id_underscored>_frontend http://<APP_ID>-frontend:80;
        proxy_pass $<app_id_underscored>_frontend;
        include /etc/nginx/snippets/proxy-common.conf;
    }
}
```

Notes:
- If the app's backend expects requests **without** the `/api/` prefix, add `rewrite ^/api/(.*)$ /$1 break;` before `proxy_pass`. If the backend already handles the `/api/` prefix internally, omit the rewrite.
- If there is no separate frontend service and nginx serves static files directly, replace the `/` block accordingly.
- Use a unique `set $variable_name` per upstream to avoid nginx resolver issues when a container is temporarily down.

### `<APP_ID>-http-redirect.conf.template`

Active after the certificate exists. Handles HTTP → HTTPS redirect while still serving ACME challenges.

```nginx
server {
    listen 80;
    server_name ${<APP_PREFIX>_SERVER_NAMES};

    # ACME challenge for certbot
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    # Redirect all other requests to HTTPS
    location / {
        return 301 https://$host$request_uri;
    }
}
```

### `<APP_ID>-https.conf.template`

TLS server block. Identical routing to the HTTP template.

```nginx
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ${<APP_PREFIX>_SERVER_NAMES};

    ssl_certificate /etc/letsencrypt/live/${<APP_PREFIX>_PRIMARY_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${<APP_PREFIX>_PRIMARY_DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    location /api/ {
        set $<app_id_underscored>_backend http://<APP_ID>-backend:<PORT>;
        proxy_pass $<app_id_underscored>_backend;
        include /etc/nginx/snippets/proxy-common.conf;
        proxy_read_timeout <TIMEOUT>;
    }

    # Mirror extra locations from the HTTP template here.

    location / {
        set $<app_id_underscored>_frontend http://<APP_ID>-frontend:80;
        proxy_pass $<app_id_underscored>_frontend;
        include /etc/nginx/snippets/proxy-common.conf;
    }
}
```

---

## 3. Update `docker-compose.yaml`

File: `web-folders/docker-compose.yaml`

Make four separate changes.

### 3a. Add Postgres env vars to `recipes-db` (if the app needs a DB)

Append to the `recipes-db` service `environment:` block, immediately before the `volumes:` key:

```yaml
      <APP_PREFIX>_POSTGRES_DB: ${<APP_PREFIX>_POSTGRES_DB:-<db_name>}
      <APP_PREFIX>_POSTGRES_USER: ${<APP_PREFIX>_POSTGRES_USER:-<db_user>}
      <APP_PREFIX>_POSTGRES_PASSWORD: ${<APP_PREFIX>_POSTGRES_PASSWORD:-change-me-<APP_ID>-db}
```

### 3b. Add the same vars to `db-password-sync`

The `db-password-sync` container reads these at every `compose up` to create/update the role and database. Append the same three vars to its `environment:` block, immediately before the `volumes:` key.

### 3c. Add service definitions

Add the new services after the last existing application's services, before `pgview:`. Follow this structure:

**If the app needs Redis**, add a dedicated Redis service first:

```yaml
  <APP_ID>-redis:
    image: redis:7-alpine
    restart: unless-stopped
    command: redis-server --save "" --appendonly no
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 10
      start_period: 5s
```

**Backend service:**

```yaml
  <APP_ID>-backend:
    image: ghcr.io/mordanov/<APP_ID>-backend:latest
    restart: unless-stopped
    environment:
      DATABASE_URL: postgresql+asyncpg://${<APP_PREFIX>_POSTGRES_USER:-<db_user>}:${<APP_PREFIX>_POSTGRES_PASSWORD:-change-me-<APP_ID>-db}@recipes-db:5432/${<APP_PREFIX>_POSTGRES_DB:-<db_name>}
      REDIS_URL: redis://<APP_ID>-redis:6379/0   # omit if no Redis
      JWT_SECRET: ${<APP_PREFIX>_JWT_SECRET:?<APP_PREFIX>_JWT_SECRET is required}
      # ... all other backend env vars from the app's .env.example ...
      APP_ENV: ${<APP_PREFIX>_APP_ENV:-production}
    expose:
      - "8000"
    depends_on:
      recipes-db:
        condition: service_healthy
      db-password-sync:
        condition: service_completed_successfully
      <APP_ID>-redis:           # omit if no Redis
        condition: service_healthy
```

**Worker service (if the app has one):**

```yaml
  <APP_ID>-worker:
    image: ghcr.io/mordanov/<APP_ID>-backend:latest   # same image as backend
    restart: unless-stopped
    command: ["python", "-m", "arq", "app.workers.scheduler.WorkerSettings"]
    environment:
      # Mirror all env vars from the backend service
    depends_on:
      recipes-db:
        condition: service_healthy
      db-password-sync:
        condition: service_completed_successfully
      <APP_ID>-redis:
        condition: service_healthy
      <APP_ID>-backend:
        condition: service_started
```

**Frontend service:**

```yaml
  <APP_ID>-frontend:
    image: ghcr.io/mordanov/<APP_ID>-frontend:latest
    restart: unless-stopped
    expose:
      - "80"
```

### 3d. Add domain vars to `nginx.environment` and `nginx.depends_on`

In the `nginx:` service, add to `environment:`:

```yaml
      <APP_PREFIX>_PRIMARY_DOMAIN: ${<APP_PREFIX>_PRIMARY_DOMAIN:-<PRIMARY_DOMAIN>}
      <APP_PREFIX>_SERVER_NAMES: ${<APP_PREFIX>_SERVER_NAMES:-<SERVER_NAMES>}
```

Add to `nginx.depends_on:`:

```yaml
      - <APP_ID>-backend
      - <APP_ID>-worker    # omit if no worker
      - <APP_ID>-frontend
```

---

## 4. Update `.env.example`

File: `web-folders/.env.example`

Add a block at the end, before the `pgview` section. Follow the same layout as every other app block:

```dotenv
# --- <APP_ID> ---
<APP_PREFIX>_PRIMARY_DOMAIN=<PRIMARY_DOMAIN>
<APP_PREFIX>_SERVER_NAMES=<SERVER_NAMES>

# Database
<APP_PREFIX>_POSTGRES_DB=<db_name>
<APP_PREFIX>_POSTGRES_USER=<db_user>
<APP_PREFIX>_POSTGRES_PASSWORD=change-me-<APP_ID>-db

# JWT
# Generate with: python -c "import secrets; print(secrets.token_hex(32))"
<APP_PREFIX>_JWT_SECRET=change-me-<APP_ID>-jwt-secret

# ... all other vars from the app's own .env.example, prefixed with <APP_PREFIX>_ ...

# CORS — comma-separated list of allowed origins
<APP_PREFIX>_CORS_ORIGINS=https://<PRIMARY_DOMAIN>

# App environment
<APP_PREFIX>_APP_ENV=production
```

Also add the mainpage landing toggle if the app has a link on the mainpage:

```dotenv
MAINPAGE_ENABLE_<MAINPAGE_KEY>=1
```

And in `docker-compose.yaml`, add the toggle to `mainpage-landing.environment:`:

```yaml
      MAINPAGE_ENABLE_<MAINPAGE_KEY>: ${MAINPAGE_ENABLE_<MAINPAGE_KEY>:-1}
```

---

## 5. Update the actual `.env` on the VPS

SSH to the VPS and append the real values for the new app to `/home/deploy/web-folders/.env`. Use the `.env.example` block as the template. Fill in:

- `<APP_PREFIX>_POSTGRES_PASSWORD` — generate with `openssl rand -hex 16`
- `<APP_PREFIX>_JWT_SECRET` — generate with `python3 -c "import secrets; print(secrets.token_hex(32))"`
- All tokens, API keys, and credentials from the app's configuration
- `<APP_PREFIX>_PRIMARY_DOMAIN` and `<APP_PREFIX>_SERVER_NAMES` — the real production hostnames

---

## 6. Create a CI workflow template

File: `web-folders/ci-workflow-templates/<APP_ID>.yml`

Copy the closest existing template (e.g. `google-timeline.yml`) and adapt it. Key points:

- Update `tags:` in each build step to `ghcr.io/mordanov/<APP_ID>-<service>:latest`
- Update the `docker compose pull` and `docker compose up -d --no-deps` service list in the deploy step
- If the frontend needs VITE_ build args baked in at build time, add them as `build-args:` and source them from `${{ secrets.VARNAME }}` or `${{ vars.VARNAME }}`
- The secrets `VPS_HOST`, `VPS_USER`, `VPS_SSH_KEY` are already set on all repos — do not add them

Add the new row to the table in `ci-workflow-templates/README.md`.

Copy the template to the app's own repository:

```bash
cp web-folders/ci-workflow-templates/<APP_ID>.yml \
   ../<app-repo>/.github/workflows/build-deploy.yml
```

---

## 7. Issue the TLS certificate

On the VPS, after the stack has been restarted with the new services in HTTP-only mode, issue the certificate:

```bash
cd /home/deploy/web-folders
docker compose exec certbot certbot certonly \
  --webroot -w /var/www/certbot \
  --email "$LETSENCRYPT_EMAIL" \
  --agree-tos --no-eff-email \
  -d <PRIMARY_DOMAIN>
```

Once the cert appears at `/etc/letsencrypt/live/<PRIMARY_DOMAIN>/`, the nginx cert-poll loop (default 300 s) will automatically switch the vhost from HTTP-only to the redirect + HTTPS templates. You can force an immediate reload:

```bash
docker compose exec nginx nginx -s reload
```

---

## 8. First-time deployment on the VPS

If the images do not yet exist on the VPS (CI has not run yet), pull and start them manually:

```bash
cd /home/deploy/web-folders

# Load env
set -a && . .env && set +a

# Pull images (bypasses pull_policy: never in compose file)
docker pull ghcr.io/mordanov/<APP_ID>-backend:latest
docker pull ghcr.io/mordanov/<APP_ID>-frontend:latest   # if exists

# Start — db-password-sync runs automatically and creates the role/DB
docker compose up -d --no-deps \
  <APP_ID>-redis \        # if app uses Redis
  <APP_ID>-backend \
  <APP_ID>-worker \       # if app has a worker
  <APP_ID>-frontend

# Reload nginx to pick up the new vhost
docker compose exec nginx nginx -s reload
```

After the first successful CI build, future deployments are fully automated.

---

## 9. Verify

Run these checks before declaring the app live:

```bash
cd /home/deploy/web-folders

# All new services are running
docker compose ps <APP_ID>-backend <APP_ID>-frontend

# Backend health check returns 200
curl -sf https://<PRIMARY_DOMAIN><HEALTH_PATH> && echo OK

# TLS cert is valid and trusted
curl -sv https://<PRIMARY_DOMAIN> 2>&1 | grep -E "subject:|issuer:|SSL"

# nginx config is valid
docker compose exec nginx nginx -t
```

---

## Checklist

- [ ] `sites.yaml` — new entry added
- [ ] `nginx/templates/<APP_ID>-http.conf.template` — created
- [ ] `nginx/templates/<APP_ID>-http-redirect.conf.template` — created
- [ ] `nginx/templates/<APP_ID>-https.conf.template` — created
- [ ] `docker-compose.yaml` — Postgres vars added to `recipes-db` and `db-password-sync`
- [ ] `docker-compose.yaml` — service definitions added
- [ ] `docker-compose.yaml` — domain vars added to `nginx.environment`
- [ ] `docker-compose.yaml` — services added to `nginx.depends_on`
- [ ] `.env.example` — new block added
- [ ] `.env` on VPS — real values filled in
- [ ] CI workflow template created and copied to app repo
- [ ] `ci-workflow-templates/README.md` — table row added
- [ ] TLS certificate issued
- [ ] Health check passes
