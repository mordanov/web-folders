# Shared Docker Compose for `family-kitchen-recipes`, `poetry-site` and `mainpage-landing`

В этой папке собран единый контур развертывания для проектов:

- один `nginx` на все сайты;
- один `certbot` на все сайты;
- отдельные backend/frontend/db сервисы там, где это нужно;
- автоматическое переключение каждого домена на HTTPS, как только для него появился сертификат.

## Что входит

- `docker-compose.yaml` — общий compose-стек;
- `.env.example` — все переменные в одном месте;
- `nginx/` — shared reverse proxy и TLS-логика;
- `issue-certificates.sh` — первичная выдача сертификатов Let’s Encrypt для всех сайтов.

## Архитектура

### `family-kitchen-recipes`
- `recipes-db` — PostgreSQL
- `recipes-backend` — FastAPI
- `recipes-frontend` — Node/Express со статикой SPA
- трафик идёт через общий `nginx`

### `poetry-site`
- `poetry-backend` — FastAPI
- фронтенд `poetry-site` отдаётся напрямую общим `nginx` из файлов проекта
- `/api` и `/uploads` проксируются в `poetry-backend`

### `mainpage-landing`
- `mainpage-landing` — статическая заглушка с быстрыми ссылками
- трафик идёт через общий `nginx`

## Как запустить

1. Скопируйте пример переменных:

```bash
cd /Users/aleksandr/Local/web-projects/web-folders
cp .env.example .env
```

2. Заполните в `.env`:
- `RECIPES_PRIMARY_DOMAIN`
- `RECIPES_SERVER_NAMES`
- `POETRY_PRIMARY_DOMAIN`
- `POETRY_SERVER_NAMES`
- `MAINPAGE_PRIMARY_DOMAIN`
- `MAINPAGE_SERVER_NAMES`
- `LETSENCRYPT_EMAIL`
- секреты и пароли обоих проектов

> В `*_SERVER_NAMES` указываются все домены сайта через пробел. Первый домен сертификата должен совпадать с `*_PRIMARY_DOMAIN`.

3. Поднимите стек в HTTP-режиме:

```bash
docker compose -f docker-compose.yaml up -d --build
```

4. Выпустите сертификаты для сайтов через один `certbot`:

```bash
chmod +x issue-certificates.sh
./issue-certificates.sh
```

5. После успешной выдачи сертификатов общий `nginx` начнёт обслуживать HTTPS.
   Если сертификаты появились уже после старта, `nginx` подхватит их автоматически при ближайшей проверке (`NGINX_CERT_POLL_INTERVAL`, по умолчанию 300 секунд).

## Обновление и продление сертификатов

Сервис `certbot` в `docker-compose.yaml` выполняет `certbot renew` в цикле.

- один контейнер `certbot` обслуживает все сайты;
- сертификаты лежат в общем volume `certbot_certs`;
- общий `nginx` отслеживает изменение сертификатов и делает `reload` без отдельного контейнера/cron.
- `issue-certificates.sh` предназначен только для первичного выпуска сертификатов и запускается вручную.

## CI/CD (web-folders)

Workflow `web-folders/.github/workflows/deploy-vps.yml`:

- не запускает `issue-certificates.sh` автоматически;
- деплоит и проверяет только конфигурационный слой (`nginx`/`certbot`);
- выводит debug-информацию (`docker compose ps` и логи) только при ошибках старта/валидации контейнеров.

## Полезные команды

```bash
# Поднять/обновить всё
cd /Users/aleksandr/Local/web-projects/web-folders
docker compose -f docker-compose.yaml up -d --build

# Логи shared nginx
docker compose -f docker-compose.yaml logs -f nginx

# Логи certbot
docker compose -f docker-compose.yaml logs -f certbot

# Посмотреть итоговую compose-конфигурацию
docker compose -f docker-compose.yaml config

# Остановить стек
docker compose -f docker-compose.yaml down
```

## Примечания

- Для `poetry-site` используется существующая SQLite-база в volume `poetry_data`, потому что именно так сейчас настроен его `docker-compose.yml`.
- Если позже захотите перевести `poetry-site` на PostgreSQL, это можно сделать отдельно, не меняя shared-`nginx`/`certbot` слой.
- До выдачи сертификатов сайты будут доступны по HTTP. После появления сертификатов для конкретного домена этот домен автоматически начнёт редиректить на HTTPS.
