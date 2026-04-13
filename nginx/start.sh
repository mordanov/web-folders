#!/bin/sh
set -eu

TEMPLATE_DIR=/etc/nginx/templates
CONF_DIR=/etc/nginx/conf.d
HTTPS_DIR=$CONF_DIR/https-enabled
CERT_DIR=/etc/letsencrypt/live
ENV_VARS='${RECIPES_PRIMARY_DOMAIN} ${RECIPES_SERVER_NAMES} ${POETRY_PRIMARY_DOMAIN} ${POETRY_SERVER_NAMES} ${MAINPAGE_PRIMARY_DOMAIN} ${MAINPAGE_SERVER_NAMES} ${MAINPAGE_404_DOMAIN} ${NEWS_PRIMARY_DOMAIN} ${NEWS_SERVER_NAMES} ${BUDGET_PRIMARY_DOMAIN} ${BUDGET_SERVER_NAMES} ${REMINDERS_PRIMARY_DOMAIN} ${REMINDERS_SERVER_NAMES} ${ADMIN_ROUTINE_PRIMARY_DOMAIN} ${ADMIN_ROUTINE_SERVER_NAMES}'

require_var() {
  var_name="$1"
  eval "var_value=\${$var_name:-}"
  if [ -z "$var_value" ]; then
    echo "Missing required variable: $var_name" >&2
    exit 1
  fi
}

render() {
  src="$1"
  dst="$2"
  envsubst "$ENV_VARS" < "$src" > "$dst"
}

has_cert() {
  domain="$1"
  [ -f "$CERT_DIR/$domain/fullchain.pem" ] && [ -f "$CERT_DIR/$domain/privkey.pem" ]
}

render_configs() {
  mkdir -p "$HTTPS_DIR"

  if has_cert "$RECIPES_PRIMARY_DOMAIN"; then
    render "$TEMPLATE_DIR/recipes-http-redirect.conf.template" "$CONF_DIR/10-recipes-http.conf"
    render "$TEMPLATE_DIR/recipes-https.conf.template" "$HTTPS_DIR/10-recipes-https.conf"
  else
    render "$TEMPLATE_DIR/recipes-http.conf.template" "$CONF_DIR/10-recipes-http.conf"
    rm -f "$HTTPS_DIR/10-recipes-https.conf"
  fi

  if has_cert "$POETRY_PRIMARY_DOMAIN"; then
    render "$TEMPLATE_DIR/poetry-http-redirect.conf.template" "$CONF_DIR/20-poetry-http.conf"
    render "$TEMPLATE_DIR/poetry-https.conf.template" "$HTTPS_DIR/20-poetry-https.conf"
  else
    render "$TEMPLATE_DIR/poetry-http.conf.template" "$CONF_DIR/20-poetry-http.conf"
    rm -f "$HTTPS_DIR/20-poetry-https.conf"
  fi

  if has_cert "$MAINPAGE_404_DOMAIN"; then
    render "$TEMPLATE_DIR/mainpage-404-http-redirect.conf.template" "$CONF_DIR/25-mainpage-404-http.conf"
    render "$TEMPLATE_DIR/mainpage-404-https.conf.template" "$HTTPS_DIR/25-mainpage-404-https.conf"
  else
    render "$TEMPLATE_DIR/mainpage-404-http.conf.template" "$CONF_DIR/25-mainpage-404-http.conf"
    rm -f "$HTTPS_DIR/25-mainpage-404-https.conf"
  fi

  if has_cert "$MAINPAGE_PRIMARY_DOMAIN"; then
    render "$TEMPLATE_DIR/mainpage-http-redirect.conf.template" "$CONF_DIR/30-mainpage-http.conf"
    render "$TEMPLATE_DIR/mainpage-https.conf.template" "$HTTPS_DIR/30-mainpage-https.conf"
  else
    render "$TEMPLATE_DIR/mainpage-http.conf.template" "$CONF_DIR/30-mainpage-http.conf"
    rm -f "$HTTPS_DIR/30-mainpage-https.conf"
  fi

  if has_cert "$NEWS_PRIMARY_DOMAIN"; then
    render "$TEMPLATE_DIR/news-http-redirect.conf.template" "$CONF_DIR/40-news-http.conf"
    render "$TEMPLATE_DIR/news-https.conf.template" "$HTTPS_DIR/40-news-https.conf"
  else
    render "$TEMPLATE_DIR/news-http.conf.template" "$CONF_DIR/40-news-http.conf"
    rm -f "$HTTPS_DIR/40-news-https.conf"
  fi

  if has_cert "$BUDGET_PRIMARY_DOMAIN"; then
    render "$TEMPLATE_DIR/budget-http-redirect.conf.template" "$CONF_DIR/50-budget-http.conf"
    render "$TEMPLATE_DIR/budget-https.conf.template" "$HTTPS_DIR/50-budget-https.conf"
  else
    render "$TEMPLATE_DIR/budget-http.conf.template" "$CONF_DIR/50-budget-http.conf"
    rm -f "$HTTPS_DIR/50-budget-https.conf"
  fi

  if has_cert "$REMINDERS_PRIMARY_DOMAIN"; then
    render "$TEMPLATE_DIR/reminders-http-redirect.conf.template" "$CONF_DIR/60-reminders-http.conf"
    render "$TEMPLATE_DIR/reminders-https.conf.template" "$HTTPS_DIR/60-reminders-https.conf"
  else
    render "$TEMPLATE_DIR/reminders-http.conf.template" "$CONF_DIR/60-reminders-http.conf"
    rm -f "$HTTPS_DIR/60-reminders-https.conf"
  fi

  if has_cert "$ADMIN_ROUTINE_PRIMARY_DOMAIN"; then
    render "$TEMPLATE_DIR/admin-routine-http-redirect.conf.template" "$CONF_DIR/70-admin-routine-http.conf"
    render "$TEMPLATE_DIR/admin-routine-https.conf.template" "$HTTPS_DIR/70-admin-routine-https.conf"
  else
    render "$TEMPLATE_DIR/admin-routine-http.conf.template" "$CONF_DIR/70-admin-routine-http.conf"
    rm -f "$HTTPS_DIR/70-admin-routine-https.conf"
  fi
}

cert_state() {
  if [ ! -d "$CERT_DIR" ]; then
    echo "no-certs"
    return
  fi

  files=$(find "$CERT_DIR" -mindepth 2 -maxdepth 2 \( -name fullchain.pem -o -name privkey.pem \) | sort || true)
  if [ -z "$files" ]; then
    echo "no-certs"
    return
  fi

  checksum_input=""
  for file in $files; do
    checksum_input="$checksum_input$(sha256sum "$file")\n"
  done

  printf '%b' "$checksum_input" | sha256sum | awk '{print $1}'
}

watch_certs() {
  previous_state=$(cert_state)

  while sleep "${NGINX_CERT_POLL_INTERVAL:-300}"; do
    current_state=$(cert_state)
    if [ "$current_state" != "$previous_state" ]; then
      echo "Certificate change detected. Regenerating nginx config..."
      previous_state="$current_state"
      render_configs
      nginx -t
      nginx -s reload
    fi
  done
}

require_var RECIPES_PRIMARY_DOMAIN
require_var RECIPES_SERVER_NAMES
require_var POETRY_PRIMARY_DOMAIN
require_var POETRY_SERVER_NAMES
require_var MAINPAGE_PRIMARY_DOMAIN
require_var MAINPAGE_SERVER_NAMES
require_var MAINPAGE_404_DOMAIN
require_var NEWS_PRIMARY_DOMAIN
require_var NEWS_SERVER_NAMES
require_var BUDGET_PRIMARY_DOMAIN
require_var BUDGET_SERVER_NAMES
require_var REMINDERS_PRIMARY_DOMAIN
require_var REMINDERS_SERVER_NAMES
require_var ADMIN_ROUTINE_PRIMARY_DOMAIN
require_var ADMIN_ROUTINE_SERVER_NAMES

render_configs
nginx -t
watch_certs &

exec nginx -g 'daemon off;'
