#!/bin/sh
# Manifest-driven nginx config generator.
#
# Reads /etc/web-folders/sites.yaml (bind-mounted by docker-compose.yaml) and:
#   - Asserts every required *_PRIMARY_DOMAIN / *_SERVER_NAMES env var is set.
#   - Renders each site's templates from nginx/templates/<id>-*.conf.template,
#     auto-promoting to HTTPS once a Let's Encrypt cert appears.
#   - Watches /etc/letsencrypt/live and reloads on cert change.
#
# Adding a new site = one entry in sites.yaml + 3 templates. No code changes here.
set -eu

TEMPLATE_DIR=/etc/nginx/templates
CONF_DIR=/etc/nginx/conf.d
HTTPS_DIR=$CONF_DIR/https-enabled
CERT_DIR=/etc/letsencrypt/live
SITES_YAML="${SITES_YAML:-/etc/web-folders/sites.yaml}"

if [ ! -f "$SITES_YAML" ]; then
  echo "FATAL: sites manifest not found at $SITES_YAML" >&2
  exit 1
fi
if ! command -v yq >/dev/null 2>&1; then
  echo "FATAL: yq is not installed in this image" >&2
  exit 1
fi

# --- helpers --------------------------------------------------------------

# Emit (id, primary_var, server_names_var, priority) sorted by priority.
manifest_iter() {
  yq -r '
    .sites
    | sort_by(.priority)
    | .[]
    | [ .id, .domain.primary_var, .domain.server_names_var, (.priority|tostring) ]
    | @tsv
  ' "$SITES_YAML"
}

# Build the envsubst variable list from the manifest.
build_env_vars_list() {
  yq -r '
    .sites[] |
    [ "${" + .domain.primary_var + "}", "${" + .domain.server_names_var + "}" ] | .[]
  ' "$SITES_YAML" | awk '!seen[$0]++' | tr '\n' ' '
}

require_var() {
  var_name="$1"
  eval "var_value=\${$var_name:-}"
  if [ -z "$var_value" ]; then
    echo "Missing required variable: $var_name" >&2
    exit 1
  fi
}

ENV_VARS="$(build_env_vars_list)"

render() {
  envsubst "$ENV_VARS" < "$1" > "$2"
}

has_cert() {
  [ -f "$CERT_DIR/$1/fullchain.pem" ] && [ -f "$CERT_DIR/$1/privkey.pem" ]
}

# POSIX-compatible indirect expansion.
get_env() {
  eval "printf '%s' \"\${$1-}\""
}

# --- assertion: every required var is set --------------------------------

manifest_iter | while IFS="$(printf '\t')" read -r id pdom_var snames_var prio; do
  require_var "$pdom_var"
  require_var "$snames_var"
done

# --- config rendering loop -----------------------------------------------

render_configs() {
  mkdir -p "$HTTPS_DIR"

  manifest_iter | while IFS="$(printf '\t')" read -r id pdom_var snames_var prio; do
    pdom=$(get_env "$pdom_var")
    prefix=$(printf '%02d' "$prio")

    http_tpl="$TEMPLATE_DIR/${id}-http.conf.template"
    redir_tpl="$TEMPLATE_DIR/${id}-http-redirect.conf.template"
    https_tpl="$TEMPLATE_DIR/${id}-https.conf.template"

    if [ ! -f "$http_tpl" ] || [ ! -f "$redir_tpl" ] || [ ! -f "$https_tpl" ]; then
      echo "WARN: site '$id' missing one of: $http_tpl, $redir_tpl, $https_tpl -- skipping" >&2
      continue
    fi

    if has_cert "$pdom"; then
      render "$redir_tpl" "$CONF_DIR/${prefix}-${id}-http.conf"
      render "$https_tpl" "$HTTPS_DIR/${prefix}-${id}-https.conf"
    else
      render "$http_tpl"  "$CONF_DIR/${prefix}-${id}-http.conf"
      rm -f "$HTTPS_DIR/${prefix}-${id}-https.conf"
    fi
  done
}

# --- cert watcher --------------------------------------------------------

cert_state() {
  if [ ! -d "$CERT_DIR" ]; then echo "no-certs"; return; fi
  files=$(find "$CERT_DIR" -mindepth 2 -maxdepth 2 \( -name fullchain.pem -o -name privkey.pem \) | sort || true)
  if [ -z "$files" ]; then echo "no-certs"; return; fi
  cs=""
  for f in $files; do cs="$cs$(sha256sum "$f")\n"; done
  printf '%b' "$cs" | sha256sum | awk '{print $1}'
}

watch_certs() {
  prev=$(cert_state)
  while sleep "${NGINX_CERT_POLL_INTERVAL:-300}"; do
    cur=$(cert_state)
    if [ "$cur" != "$prev" ]; then
      echo "Certificate change detected. Regenerating nginx config..."
      prev="$cur"
      render_configs
      nginx -t
      nginx -s reload
    fi
  done
}

render_configs
nginx -t
watch_certs &

exec nginx -g 'daemon off;'


