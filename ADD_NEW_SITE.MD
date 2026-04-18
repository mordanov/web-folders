# ADD NEW SITE

Инструкция по добавлению нового сайта в общий стек `web-folders`.

С переходом на манифест `sites.yaml` (Phase: data-driven configuration)
скрипты `nginx/start.sh`, `issue-certificates.sh`, `deploy-one-db.sh`,
`scripts/sync-app-db-users.sh` и `.github/workflows/deploy-vps.yml` стали
универсальными — они **больше не редактируются** при добавлении сайта.

Достаточно 4 шагов.

---

## Checklist

- [ ] **1.** Добавить запись в `sites.yaml`
- [ ] **2.** Положить 3 nginx-шаблона в `nginx/templates/`
- [ ] **3.** Добавить переменные в `.env` / `.env.example`
- [ ] **4.** Добавить сервисы в `docker-compose.yaml` (backend/frontend +
            проброс env-переменных в `nginx.environment` и `depends_on`)

После — поднять стек, при необходимости выпустить сертификат.

---

## 1) `sites.yaml`

Один блок описывает сайт целиком. Например:

```yaml
- id: newsite                       # совпадает с префиксом nginx-шаблонов
  priority: 90                      # порядок рендеринга (используется как 90-newsite-*.conf)
  cert_label: my-new-site           # как certbot его покажет в логах
  domain:
    primary_var: NEWSITE_PRIMARY_DOMAIN
    server_names_var: NEWSITE_SERVER_NAMES
  db:                               # опционально — уберите, если БД не нужна
    db_var: NEWSITE_POSTGRES_DB
    user_var: NEWSITE_POSTGRES_USER
    password_var: NEWSITE_POSTGRES_PASSWORD
  health_path: /health              # опционально — путь, по которому deploy-one-db.sh
                                    # пингует сайт через nginx после запуска
  compose_services:                 # опционально — для list/build/up
    - newsite-backend
    - newsite-frontend
```

Поля `db`, `health_path`, `compose_services` — необязательные. Уберите
ненужные.

## 2) Nginx-шаблоны

В `nginx/templates/` создать 3 файла со строго именованными префиксами:
```
nginx/templates/newsite-http.conf.template
nginx/templates/newsite-http-redirect.conf.template
nginx/templates/newsite-https.conf.template
```
Можно скопировать из `reminders-*.conf.template` или `archive-*.conf.template`
и заменить `${REMINDERS_…}` → `${NEWSITE_…}`, `reminders-backend` → `newsite-backend`.

`nginx/start.sh` сам поймёт, что есть три файла с префиксом `newsite-`,
сам отрендерит и сам переключится на HTTPS, как только появится
сертификат для `${NEWSITE_PRIMARY_DOMAIN}`.

## 3) `.env` / `.env.example`

Добавить все переменные, на которые ссылается манифест:

```dotenv
NEWSITE_PRIMARY_DOMAIN=newsite.example.com
NEWSITE_SERVER_NAMES=newsite.example.com www.newsite.example.com

# Если есть db: блок в манифесте — добавить ещё:
NEWSITE_POSTGRES_DB=newsite
NEWSITE_POSTGRES_USER=newsite_user
NEWSITE_POSTGRES_PASSWORD=change-me-newsite-db
```

## 4) `docker-compose.yaml`

Добавить сервисы (`newsite-backend`, `newsite-frontend`, …), пробросить
переменные в `nginx.environment` и в `nginx.depends_on`:

```yaml
services:
  newsite-backend:
    build: { context: ../newsite/backend }
    restart: unless-stopped
    environment:
      DATABASE_URL: postgresql+asyncpg://${NEWSITE_POSTGRES_USER}:${NEWSITE_POSTGRES_PASSWORD}@recipes-db:5432/${NEWSITE_POSTGRES_DB}
      # …
    expose: ["8000"]
    depends_on:
      recipes-db: { condition: service_healthy }
      db-password-sync: { condition: service_completed_successfully }

  newsite-frontend:
    build: { context: ../newsite/frontend }
    restart: unless-stopped
    expose: ["80"]

  nginx:
    environment:
      # …existing…
      NEWSITE_PRIMARY_DOMAIN: ${NEWSITE_PRIMARY_DOMAIN:-newsite.local}
      NEWSITE_SERVER_NAMES: ${NEWSITE_SERVER_NAMES:-newsite.local}
    depends_on:
      # …existing…
      - newsite-backend
      - newsite-frontend
```

`db-password-sync` уже сам прочитает `sites.yaml` и создаст роль/БД,
если в манифесте есть `db:` блок и переменные пробрасываются ему через
`environment:`.

> Если у вас уже автоматизировано чтение `nginx.environment` из `sites.yaml`
> через extension fields — пропустите эту часть. В текущей реализации
> compose-файл редактируется вручную (см. также раздел "Что бы ещё
> улучшить" внизу).

---

## Поднять и проверить локально

```bash
cd /Users/aleksandr/Local/web-projects/web-folders
docker compose up -d --build
```

Проверка роутинга:

```bash
curl -I -H "Host: newsite.local" http://127.0.0.1
```

Локальные хосты:

```bash
sudo sh -c 'echo "127.0.0.1 newsite.local" >> /etc/hosts'
```

---

## Первичная выдача сертификата

```bash
cd /Users/aleksandr/Local/web-projects/web-folders
./issue-certificates.sh
```

`issue-certificates.sh` сам прочитает `sites.yaml` и выпустит сертификат
для нового сайта. `nginx/start.sh` сам подхватит его (по таймеру
`NGINX_CERT_POLL_INTERVAL`).

---

## Зависимости

Хост (где запускаются `issue-certificates.sh`, `deploy-one-db.sh`):
- `bash` 4+
- `docker` / `docker compose`
- `yq` (https://github.com/mikefarah/yq) v4+
  - macOS: `brew install yq`
  - Debian/Ubuntu:
    ```bash
    sudo wget -qO /usr/local/bin/yq \
      https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
    sudo chmod +x /usr/local/bin/yq
    ```

В контейнерах `yq` ставится автоматически (`apk add yq` в `nginx/Dockerfile`
и в `scripts/sync-app-db-users.sh`).

---

## Что бы ещё улучшить (TODO)

- Сейчас `nginx.environment` в `docker-compose.yaml` редактируется руками
  при добавлении сайта. Это можно убрать, перейдя на extension fields
  (`x-site-env: &site-env { ... }`) или на `env_file` с генерируемым
  файлом `nginx.env`. Оставлено намеренно явным для читаемости.
- `compose_services` в манифесте можно использовать и в самом
  `docker-compose.yaml` через `profiles:`, чтобы поднимать по
  одному сайту: `docker compose --profile newsite up -d`.

