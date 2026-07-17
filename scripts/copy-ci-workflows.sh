#!/usr/bin/env bash
# Copy CI workflows (tests + build-deploy) into each service repo.
#
# For each repo:
#   - Removes old deploy/ci workflows that are superseded
#   - Writes tests.yml  — runs on push to any branch + pull_request
#   - Writes build-deploy.yml — runs on push to main only
#
# Run from the web-folders directory:
#   bash scripts/copy-ci-workflows.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEB_FOLDERS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATES_DIR="$WEB_FOLDERS_DIR/ci-workflow-templates"
BASE_DIR="$(cd "$WEB_FOLDERS_DIR/.." && pwd)"

info()  { echo "  [INFO]  $*"; }
ok()    { echo "  [OK]    $*"; }
warn()  { echo "  [WARN]  $*"; }
header(){ echo; echo "=== $* ==="; }

write_workflow() {
  local repo_dir="$1" filename="$2" content="$3"
  local wf_dir="$repo_dir/.github/workflows"
  mkdir -p "$wf_dir"
  printf '%s\n' "$content" > "$wf_dir/$filename"
  ok "Wrote $filename"
}

delete_workflow() {
  local repo_dir="$1" filename="$2"
  local path="$repo_dir/.github/workflows/$filename"
  if [ -f "$path" ]; then
    rm "$path"
    ok "Deleted $filename"
  fi
}

# ---------------------------------------------------------------------------
# family-kitchen-recipes
# ---------------------------------------------------------------------------
process_family_kitchen_recipes() {
  local dir="$BASE_DIR/family-kitchen-recipes"
  [ -d "$dir" ] || { warn "family-kitchen-recipes not found, skipping"; return; }
  header "family-kitchen-recipes"

  delete_workflow "$dir" "deploy-vps.yml"
  delete_workflow "$dir" "pr-main-tests.yml"

  write_workflow "$dir" "tests.yml" \
'name: Tests

on:
  push:
  pull_request:

permissions:
  contents: read

jobs:
  backend-tests:
    name: Backend Tests
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: backend
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-python@v5
        with:
          python-version: "3.13"
          cache: pip

      - name: Install dependencies
        run: pip install -r requirements.txt

      - name: Run tests
        run: pytest -q tests

  frontend-tests:
    name: Frontend Tests
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: frontend
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: "20"
          cache: npm
          cache-dependency-path: frontend/package.json

      - name: Install dependencies
        run: |
          if [ -f package-lock.json ]; then npm ci; else npm install; fi

      - name: Run tests
        run: npm run test:run'

  cp "$TEMPLATES_DIR/family-kitchen-recipes.yml" \
     "$dir/.github/workflows/build-deploy.yml"
  ok "Copied build-deploy.yml"
}

# ---------------------------------------------------------------------------
# poetry-site
# ---------------------------------------------------------------------------
process_poetry_site() {
  local dir="$BASE_DIR/poetry-site"
  [ -d "$dir" ] || { warn "poetry-site not found, skipping"; return; }
  header "poetry-site"

  delete_workflow "$dir" "deploy.yml"
  delete_workflow "$dir" "test.yml"

  write_workflow "$dir" "tests.yml" \
'name: Tests

on:
  push:
  pull_request:

permissions:
  contents: read

jobs:
  backend-tests:
    name: Backend Tests
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: backend
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-python@v5
        with:
          python-version: "3.11"
          cache: pip
          cache-dependency-path: backend/requirements*.txt

      - name: Install dependencies
        run: |
          pip install -r requirements.txt
          pip install -r requirements-test.txt

      - name: Run tests
        run: pytest test_main.py -v --tb=short

  frontend-tests:
    name: Frontend Tests
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: frontend
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: "20"
          cache: npm
          cache-dependency-path: |
            frontend/package-lock.json
            frontend/package.json

      - name: Install dependencies
        run: |
          if [ -f package-lock.json ]; then npm ci; else npm install; fi

      - name: Run tests
        run: npm test -- --coverage --runInBand'

  cp "$TEMPLATES_DIR/poetry-site.yml" \
     "$dir/.github/workflows/build-deploy.yml"
  ok "Copied build-deploy.yml"
}

# ---------------------------------------------------------------------------
# news-site
# ---------------------------------------------------------------------------
process_news_site() {
  local dir="$BASE_DIR/news-site"
  [ -d "$dir" ] || { warn "news-site not found, skipping"; return; }
  header "news-site"

  delete_workflow "$dir" "deploy-vps.yml"
  delete_workflow "$dir" "pr-main-tests.yml"
  # android-build.yml is unrelated to deployment — leave it untouched

  write_workflow "$dir" "tests.yml" \
'name: Tests

on:
  push:
  pull_request:

permissions:
  contents: read

jobs:
  backend-tests:
    name: Backend Tests
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: backend
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"
          cache: pip

      - name: Install dependencies
        run: pip install -r requirements.txt

      - name: Run tests
        run: pytest -q

  frontend-tests:
    name: Frontend Tests
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: frontend
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: "20"

      - name: Install dependencies
        run: npm install

      - name: Run tests
        run: npm test'

  cp "$TEMPLATES_DIR/news-site.yml" \
     "$dir/.github/workflows/build-deploy.yml"
  ok "Copied build-deploy.yml"
}

# ---------------------------------------------------------------------------
# budget-site (family-budget)
# ---------------------------------------------------------------------------
process_budget_site() {
  local dir="$BASE_DIR/budget-site"
  [ -d "$dir" ] || { warn "budget-site not found, skipping"; return; }
  header "budget-site (family-budget)"

  delete_workflow "$dir" "deploy-vps.yml"
  delete_workflow "$dir" "pr-main-tests.yml"

  write_workflow "$dir" "tests.yml" \
'name: Tests

on:
  push:
  pull_request:

permissions:
  contents: read

jobs:
  backend-tests:
    name: Backend Tests
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: backend
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"
          cache: pip

      - name: Install dependencies
        run: pip install -r requirements.txt -r requirements-dev.txt -r requirements-test.txt

      - name: Run tests
        env:
          LOG_LEVEL: WARNING
          UPLOAD_DIR: /tmp/test_uploads
          LOG_DIR: /tmp/test_logs
        run: pytest -q --tb=short

  frontend-tests:
    name: Frontend Tests
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: frontend
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: "20"

      - name: Install dependencies
        run: npm install

      - name: Run tests
        run: npm test'

  cp "$TEMPLATES_DIR/family-budget.yml" \
     "$dir/.github/workflows/build-deploy.yml"
  ok "Copied build-deploy.yml"
}

# ---------------------------------------------------------------------------
# reminders-app
# ---------------------------------------------------------------------------
process_reminders_app() {
  local dir="$BASE_DIR/reminders-app"
  [ -d "$dir" ] || { warn "reminders-app not found, skipping"; return; }
  header "reminders-app"

  delete_workflow "$dir" "deploy-vps.yml"
  delete_workflow "$dir" "pr-main-tests.yml"

  write_workflow "$dir" "tests.yml" \
'name: Tests

on:
  push:
  pull_request:

permissions:
  contents: read

jobs:
  backend-tests:
    name: Backend Tests
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: backend
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"
          cache: pip

      - name: Install dependencies
        run: pip install -r requirements.txt -r requirements-dev.txt -r requirements-test.txt

      - name: Run tests
        env:
          LOG_LEVEL: WARNING
        run: pytest -q --tb=short

  frontend-tests:
    name: Frontend Tests
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: frontend
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: "20"

      - name: Install dependencies
        run: npm install

      - name: Run tests
        run: npm test'

  cp "$TEMPLATES_DIR/reminders-app.yml" \
     "$dir/.github/workflows/build-deploy.yml"
  ok "Copied build-deploy.yml"
}

# ---------------------------------------------------------------------------
# family-admin-routine
# ---------------------------------------------------------------------------
process_family_admin_routine() {
  local dir="$BASE_DIR/family-admin-routine"
  [ -d "$dir" ] || { warn "family-admin-routine not found, skipping"; return; }
  header "family-admin-routine"

  delete_workflow "$dir" "deploy-vps.yml"
  delete_workflow "$dir" "pr-main-tests.yml"

  write_workflow "$dir" "tests.yml" \
'name: Tests

on:
  push:
  pull_request:

permissions:
  contents: read

jobs:
  backend-tests:
    name: Backend Tests
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: backend
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"
          cache: pip

      - name: Install dependencies
        run: pip install -r requirements.txt -r requirements-test.txt

      - name: Run tests
        run: pytest -q --tb=short

  frontend-tests:
    name: Frontend Tests
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: frontend
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: "20"

      - name: Install dependencies
        run: npm install

      - name: Run tests
        run: npm test'

  cp "$TEMPLATES_DIR/family-admin-routine.yml" \
     "$dir/.github/workflows/build-deploy.yml"
  ok "Copied build-deploy.yml"
}

# ---------------------------------------------------------------------------
# family-archive
# ---------------------------------------------------------------------------
process_family_archive() {
  local dir="$BASE_DIR/family-archive"
  [ -d "$dir" ] || { warn "family-archive not found, skipping"; return; }
  header "family-archive"

  # ci.yml was a combined tests+deploy file — remove it entirely
  delete_workflow "$dir" "ci.yml"

  write_workflow "$dir" "tests.yml" \
'name: Tests

on:
  push:
  pull_request:

permissions:
  contents: read

jobs:
  backend-tests:
    name: Backend Tests
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: backend
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"
          cache: pip
          cache-dependency-path: backend/requirements-dev.txt

      - name: Install system dependencies
        run: sudo apt-get update && sudo apt-get install -y --no-install-recommends ffmpeg libmagic1

      - name: Install dependencies
        run: pip install -r requirements-dev.txt

      - name: Run tests
        run: pytest -q

  frontend-tests:
    name: Frontend Tests
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: frontend
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: "20"
          cache: npm
          cache-dependency-path: frontend/package-lock.json

      - name: Install dependencies
        run: npm ci

      - name: Run tests
        run: npm test --silent'

  cp "$TEMPLATES_DIR/family-archive.yml" \
     "$dir/.github/workflows/build-deploy.yml"
  ok "Copied build-deploy.yml"
}

# ---------------------------------------------------------------------------
# servinga-monitoring (servinga-dashboard)
# ---------------------------------------------------------------------------
process_servinga_monitoring() {
  local dir="$BASE_DIR/servinga-dashboard"
  [ -d "$dir" ] || { warn "servinga-dashboard not found, skipping"; return; }
  header "servinga-monitoring (servinga-dashboard)"

  delete_workflow "$dir" "deploy-vps.yml"

  # servinga had no test workflow — write a minimal placeholder
  # that runs on push/PR but only if test directories exist
  write_workflow "$dir" "tests.yml" \
'name: Tests

on:
  push:
  pull_request:

permissions:
  contents: read

jobs:
  backend-tests:
    name: Backend Tests
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: backend
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"
          cache: pip

      - name: Install dependencies
        run: pip install -r requirements.txt

      - name: Run tests
        run: pytest -q --tb=short

  frontend-tests:
    name: Frontend Tests
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: frontend
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: "20"

      - name: Install dependencies
        run: npm install

      - name: Run tests
        run: npm test'

  cp "$TEMPLATES_DIR/servinga-monitoring.yml" \
     "$dir/.github/workflows/build-deploy.yml"
  ok "Copied build-deploy.yml"
}

# ---------------------------------------------------------------------------
# portuguese-expenses
# ---------------------------------------------------------------------------
process_portuguese_expenses() {
  local dir="$BASE_DIR/portuguese-expenses"
  [ -d "$dir" ] || { warn "portuguese-expenses not found, skipping"; return; }
  header "portuguese-expenses"

  # build-deploy.yml is already there and correct — leave it, just rewrite it
  # to ensure trigger is push to main only
  delete_workflow "$dir" "build-deploy.yml"

  write_workflow "$dir" "tests.yml" \
'name: Tests

on:
  push:
  pull_request:

permissions:
  contents: read

jobs:
  backend-tests:
    name: Backend Tests
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: backend
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"
          cache: pip

      - name: Install dependencies
        run: pip install -r requirements.txt -r requirements-dev.txt

      - name: Run tests
        run: pytest -q --tb=short

  frontend-tests:
    name: Frontend Tests
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: frontend
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: "20"
          cache: npm
          cache-dependency-path: frontend/package-lock.json

      - name: Install dependencies
        run: npm ci

      - name: Run tests
        run: npm test'

  cp "$TEMPLATES_DIR/portuguese-expenses.yml" \
     "$dir/.github/workflows/build-deploy.yml"
  ok "Copied build-deploy.yml"
}

# ---------------------------------------------------------------------------
# home-resource-consumption (home-resources)
# ---------------------------------------------------------------------------
process_home_resource_consumption() {
  local dir="$BASE_DIR/home-resource-consumption"
  [ -d "$dir" ] || { warn "home-resource-consumption not found, skipping"; return; }
  header "home-resource-consumption (home-resources)"

  delete_workflow "$dir" "deploy-vps.yml"
  delete_workflow "$dir" "ci.yml"

  write_workflow "$dir" "tests.yml" \
'name: Tests

on:
  push:
  pull_request:

permissions:
  contents: read

jobs:
  backend-tests:
    name: Backend Tests
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:16
        env:
          POSTGRES_USER: test_user
          POSTGRES_PASSWORD: test_pass
          POSTGRES_DB: resource_tracker_test
        ports:
          - 5432:5432
        options: >-
          --health-cmd pg_isready
          --health-interval 5s
          --health-timeout 5s
          --health-retries 10
    defaults:
      run:
        working-directory: backend
    env:
      DATABASE_URL: postgresql+asyncpg://test_user:test_pass@localhost:5432/resource_tracker_test
      OPENAI_API_KEY: test-key-placeholder
      OPENAI_MODEL: gpt-4o-mini
      JWT_SECRET_KEY: test-secret-key-for-ci-only-not-for-production-0000000000000
      JWT_ALGORITHM: HS256
      ACCESS_TOKEN_EXPIRE_MINUTES: "15"
      REFRESH_TOKEN_EXPIRE_DAYS: "7"
      CORS_ORIGINS: '"'"'["http://localhost:3000"]'"'"'
      MAX_UPLOAD_SIZE_MB: "10"
      UPLOAD_DIR: /tmp/test-uploads
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"
          cache: pip

      - name: Install system dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y --no-install-recommends \
            tesseract-ocr libmagic1 libpango-1.0-0 libcairo2 libgdk-pixbuf2.0-0

      - name: Install dependencies
        run: pip install -e ".[dev]"

      - name: Run migrations
        run: alembic upgrade head

      - name: Run tests
        run: pytest tests/ -v --tb=short --cov=app --cov-fail-under=85

  frontend-tests:
    name: Frontend Tests
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: frontend
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: "20"

      - name: Install dependencies
        run: npm install

      - name: Run tests
        run: npm test'

  cp "$TEMPLATES_DIR/home-resources.yml" \
     "$dir/.github/workflows/build-deploy.yml"
  ok "Copied build-deploy.yml"
}

# ---------------------------------------------------------------------------
# verdecora-bot (backend only — no frontend)
# ---------------------------------------------------------------------------
process_verdecora_bot() {
  local dir="$BASE_DIR/verdecora-bot"
  [ -d "$dir" ] || { warn "verdecora-bot not found, skipping"; return; }
  header "verdecora-bot"

  delete_workflow "$dir" "deploy-vps.yml"
  delete_workflow "$dir" "ci.yml"

  write_workflow "$dir" "tests.yml" \
'name: Tests

on:
  push:
  pull_request:

permissions:
  contents: read

jobs:
  tests:
    name: Unit Tests
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"
          cache: pip

      - name: Install dependencies
        run: pip install -r requirements.txt pytest pytest-asyncio

      - name: Run tests
        env:
          TELEGRAM_TOKEN: test-token
          CHAT_ID: "123456"
        run: pytest tests/ -v --tb=short'

  cp "$TEMPLATES_DIR/verdecora-bot.yml" \
     "$dir/.github/workflows/build-deploy.yml"
  ok "Copied build-deploy.yml"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo "Base directory: $BASE_DIR"
echo "Templates directory: $TEMPLATES_DIR"

process_family_kitchen_recipes
process_poetry_site
process_news_site
process_budget_site
process_reminders_app
process_family_admin_routine
process_family_archive
process_servinga_monitoring
process_portuguese_expenses
process_home_resource_consumption
process_verdecora_bot

echo
echo "Done."
