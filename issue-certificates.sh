#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yaml"
ENV_FILE="$SCRIPT_DIR/.env"

if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

require_var() {
  var_name="$1"
  eval "var_value=\${$var_name:-}"
  if [ -z "$var_value" ]; then
    echo "Missing required variable: $var_name" >&2
    exit 1
  fi
}

require_var LETSENCRYPT_EMAIL
require_var RECIPES_PRIMARY_DOMAIN
require_var RECIPES_SERVER_NAMES
require_var POETRY_PRIMARY_DOMAIN
require_var POETRY_SERVER_NAMES

run_certbot() {
  site_label="$1"
  primary_domain="$2"
  all_domains="$3"

  echo "Issuing certificate for $site_label: $all_domains"

  set -- certonly \
    --webroot \
    --webroot-path /var/www/certbot \
    --email "$LETSENCRYPT_EMAIL" \
    --agree-tos \
    --no-eff-email

  if [ "${CERTBOT_STAGING:-0}" = "1" ]; then
    set -- "$@" --staging
  fi

  set -- "$@" -d "$primary_domain"
  for domain in $all_domains; do
    if [ "$domain" != "$primary_domain" ]; then
      set -- "$@" -d "$domain"
    fi
  done

  docker compose -f "$COMPOSE_FILE" run --rm certbot "$@"
}

run_certbot "family-kitchen-recipes" "$RECIPES_PRIMARY_DOMAIN" "$RECIPES_SERVER_NAMES"
run_certbot "poetry-site" "$POETRY_PRIMARY_DOMAIN" "$POETRY_SERVER_NAMES"

docker compose -f "$COMPOSE_FILE" exec nginx nginx -s reload >/dev/null 2>&1 || true

echo "Done. If nginx was already running, it has been reloaded."

