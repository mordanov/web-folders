# ADD NEW SITE

Инструкция по добавлению нового сайта в общий стек `web-folders` (один `nginx` + один `certbot`).

## Checklist

- [ ] Добавить сервисы нового сайта в `docker-compose.yaml`
- [ ] Добавить доменные и секретные переменные в `.env` и `.env.example`
- [ ] Создать nginx-шаблоны: HTTP, HTTP->HTTPS redirect, HTTPS
- [ ] Обновить `nginx/start.sh` для авто-переключения при появлении сертификата
- [ ] Обновить `issue-certificates.sh` для первичной выдачи сертификата нового сайта
- [ ] Поднять стек и проверить роутинг локально

---

## 1) Добавьте сервисы сайта в `docker-compose.yaml`

Откройте `web-folders/docker-compose.yaml` и добавьте сервисы проекта.

Типовой вариант:
- `newsite-backend` с `expose: "8000"`
- при необходимости `newsite-frontend` (или отдача статики напрямую из `nginx` через volume)
- добавьте сервисы в `nginx.depends_on`

Пример фрагмента:

```yaml
services:
  newsite-backend:
    build:
      context: ../new-site/backend
    restart: unless-stopped
    expose:
      - "8000"

  nginx:
    # ...existing code...
    environment:
      # ...existing code...
      NEWSITE_PRIMARY_DOMAIN: ${NEWSITE_PRIMARY_DOMAIN:-newsite.local}
      NEWSITE_SERVER_NAMES: ${NEWSITE_SERVER_NAMES:-newsite.local}
    volumes:
      # если сайт статический:
      - ../new-site/frontend:/srv/new-site:ro
    depends_on:
      # ...existing code...
      - newsite-backend
```

---

## 2) Добавьте переменные в `.env` и `.env.example`

Добавьте домены нового сайта:

```dotenv
NEWSITE_PRIMARY_DOMAIN=newsite.example.com
NEWSITE_SERVER_NAMES=newsite.example.com www.newsite.example.com
```

Для локальной разработки:

```dotenv
NEWSITE_PRIMARY_DOMAIN=newsite.local
NEWSITE_SERVER_NAMES=newsite.local
```

---

## 3) Создайте nginx-шаблоны нового сайта

В `web-folders/nginx/templates` добавьте 3 файла:

- `newsite-http.conf.template`
- `newsite-http-redirect.conf.template`
- `newsite-https.conf.template`

### Логика шаблонов

- `http`: обслуживает сайт и `/.well-known/acme-challenge/`
- `http-redirect`: редирект на HTTPS, но challenge остаётся доступным по HTTP
- `https`: тот же роутинг, плюс TLS-сертификаты

Пример TLS-блока в `newsite-https.conf.template`:

```nginx
ssl_certificate /etc/letsencrypt/live/${NEWSITE_PRIMARY_DOMAIN}/fullchain.pem;
ssl_certificate_key /etc/letsencrypt/live/${NEWSITE_PRIMARY_DOMAIN}/privkey.pem;
ssl_protocols TLSv1.2 TLSv1.3;
ssl_ciphers HIGH:!aNULL:!MD5;
```

Если есть API, проксируйте так же, как в других шаблонах, через:

```nginx
include /etc/nginx/snippets/proxy-common.conf;
```

---

## 4) Обновите `nginx/start.sh`

Откройте `web-folders/nginx/start.sh` и добавьте новый сайт по аналогии с `recipes` и `poetry`:

1. В `ENV_VARS`:
- `${NEWSITE_PRIMARY_DOMAIN} ${NEWSITE_SERVER_NAMES}`

2. В блок обязательных переменных:
- `require_var NEWSITE_PRIMARY_DOMAIN`
- `require_var NEWSITE_SERVER_NAMES`

3. В `render_configs()`:
- если сертификат есть -> рендер `newsite-http-redirect` + `newsite-https`
- если сертификата нет -> рендер `newsite-http` и удаление HTTPS-конфига

---

## 5) Обновите `issue-certificates.sh`

Откройте `web-folders/issue-certificates.sh` и добавьте:

- обязательные переменные:
  - `NEWSITE_PRIMARY_DOMAIN`
  - `NEWSITE_SERVER_NAMES`
- вызов Certbot:

```sh
run_certbot "new-site" "$NEWSITE_PRIMARY_DOMAIN" "$NEWSITE_SERVER_NAMES"
```

Так один контейнер `certbot` будет выпускать/обновлять сертификаты уже для 3 сайтов.

---

## 6) Поднимите стек и проверьте локально

```bash
cd /Users/aleksandr/Local/web-projects/web-folders
docker compose up -d --build
```

Проверка роутинга по Host:

```bash
curl -I -H "Host: newsite.local" http://127.0.0.1
curl -I -H "Host: recipes.local" http://127.0.0.1
curl -I -H "Host: poetry.local" http://127.0.0.1
```

Добавьте локальные домены в `/etc/hosts`:

```bash
sudo sh -c 'echo "127.0.0.1 recipes.local poetry.local newsite.local" >> /etc/hosts'
```

После этого откройте в браузере:

```text
http://newsite.local
http://recipes.local
http://poetry.local
```

---

## Первичная выдача сертификатов

После проверки HTTP-запуска выпустите сертификат(ы):

```bash
cd /Users/aleksandr/Local/web-projects/web-folders
./issue-certificates.sh
```

`nginx` подхватит сертификаты автоматически (по таймеру `NGINX_CERT_POLL_INTERVAL`).

---

## Рекомендация по масштабированию

Текущая схема `start.sh` с явными блоками подходит для 2-4 сайтов.
Если сайтов станет больше, лучше перейти на data-driven конфиг (список сайтов в env + цикл), чтобы добавлять проект без правки shell-логики.

