# CI Workflow Templates

Each `.yml` file in this directory is a ready-to-copy GitHub Actions workflow for the corresponding repository. Copy the file to `.github/workflows/build-deploy.yml` in the target repo.

## One-time VPS setup

### 1. Create a GitHub PAT for `docker login`

The VPS needs read access to ghcr.io to pull private images.

1. Go to **GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic)**
2. Click **Generate new token (classic)**
3. Set a note (e.g. `vps-ghcr-pull`), no expiry (or long expiry)
4. Select only the **`read:packages`** scope
5. Click **Generate token** and copy it

Then on the VPS, log in once:

```bash
echo YOUR_PAT | docker login ghcr.io -u mordanov --password-stdin
```

Credentials are saved to `~/.docker/config.json` and persist across reboots. `docker compose pull` will use them automatically.

### 2. Verify the login works

```bash
docker pull ghcr.io/mordanov/recipes-backend:latest
```

(After the first CI build has pushed an image.)

## Applying a workflow to a repo

```bash
cp ci-workflow-templates/family-kitchen-recipes.yml \
   ../family-kitchen-recipes/.github/workflows/build-deploy.yml
```

Repeat for each repo. Secrets `VPS_HOST`, `VPS_USER`, `VPS_SSH_KEY` are already set on each repo.

## Repos and their workflow files

| Repo | Workflow file | Services |
|---|---|---|
| `family-kitchen-recipes` | `family-kitchen-recipes.yml` | recipes-backend, recipes-frontend |
| `poetry-site` | `poetry-site.yml` | poetry-backend |
| `news-site` | `news-site.yml` | news-backend, news-frontend |
| `family-budget` | `family-budget.yml` | budget-backend, budget-frontend |
| `reminders-app` | `reminders-app.yml` | reminders-backend, reminders-frontend |
| `family-admin-routine` | `family-admin-routine.yml` | admin-routine-backend, admin-routine-frontend |
| `family-archive` | `family-archive.yml` | archive-backend, archive-frontend |
| `servinga-monitoring` | `servinga-monitoring.yml` | servinga-backend, servinga-frontend |
| `portuguese-expenses` | `portuguese-expenses.yml` | portuguese-expenses-backend, portuguese-expenses-frontend |
| `home-resources` | `home-resources.yml` | home-resources-backend, home-resources-frontend |
| `verdecora-bot` | `verdecora-bot.yml` | verdecora-bot |
| `google-timeline-web-app` | `google-timeline.yml` | google-timeline-backend, google-timeline-importer, google-timeline-frontend |
| `travelsearch` | `travelsearch.yml` | travelsearch-backend, travelsearch-worker, travelsearch-frontend |

`dark-factory` (ticket-manager) is excluded — being offboarded.

## Notes on special cases

### `family-archive` — replicas
The deploy step uses `--scale archive-backend=${ARCHIVE_REPLICAS:-2}`. The replica count is still controlled by the `ARCHIVE_REPLICAS` env var in `.env` on the VPS.

### `family-budget` and `family-admin-routine` — build args
These frontends have VITE_ build args. They are set as **repository variables** (not secrets, since they're domain names) in the GitHub repo settings:
- `family-budget`: `BUDGET_KITCHEN_API_URL`, `BUDGET_KITCHEN_SERVICE_USER`; secret: `BUDGET_KITCHEN_SERVICE_PASSWORD`
- `family-admin-routine`: `VITE_PGVIEW_URL`
- `portuguese-expenses`: `PORTUGUESE_EXPENSES_VITE_API_BASE_URL`
- `google-timeline-web-app`: secret: `GOOGLE_TIMELINE_MAPS_API_KEY`

Set variables at: **Repo → Settings → Secrets and variables → Actions → Variables tab**

### `poetry-site` — frontend not in CI
The poetry frontend is served as static files directly by nginx (volume-mounted). It has no docker service to build, so no frontend job is needed.

### Migration order (recommended)
1. Do the VPS docker login first
2. Add workflows to low-risk repos first (e.g. verdecora-bot, news-site)
3. Verify images appear in ghcr.io and the VPS deploy step completes
4. Migrate remaining repos one at a time
5. The `docker-compose.yaml` in web-folders is already updated with `image:` references — the stack will use pulled images on the next `web-folders` deploy
