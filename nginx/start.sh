#!/bin/sh
set -eu

TEMPLATE_DIR=/etc/nginx/templates
CONF_DIR=/etc/nginx/conf.d
HTTPS_DIR=$CONF_DIR/https-enabled
CERT_DIR=/etc/letsencrypt/live
ENV_VARS='${RECIPES_PRIMARY_DOMAIN} ${RECIPES_SERVER_NAMES} ${POETRY_PRIMARY_DOMAIN} ${POETRY_SERVER_NAMES}'

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

render_configs
nginx -t
watch_certs &

exec nginx -g 'daemon off;'

