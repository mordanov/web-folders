#!/usr/bin/env bash
# Issue or renew Let's Encrypt certificates for every site listed in sites.yaml.
# Loops the manifest via scripts/sites-lib.sh.
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yaml"
ENV_FILE="$SCRIPT_DIR/.env"

# shellcheck source=scripts/sites-lib.sh
. "$SCRIPT_DIR/scripts/sites-lib.sh"

if [ -f "$ENV_FILE" ]; then
  set -a
  set +u
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set -u
  set +a
fi

require_var() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    echo "Missing required variable: $name" >&2
    exit 1
  fi
}

require_var LETSENCRYPT_EMAIL

# Validate every domain var referenced by the manifest exists in the env.
while IFS= read -r v; do
  require_var "$v"
done < <(sites_required_env_vars)

run_certbot() {
  local site_label="$1" primary_domain="$2" all_domains="$3"
  echo "Issuing certificate for $site_label: $all_domains"

  local args=(
    certonly
    --webroot
    --webroot-path /var/www/certbot
    --email "$LETSENCRYPT_EMAIL"
    --agree-tos
    --no-eff-email
    --keep-until-expiring
    --non-interactive
  )
  if [ "${CERTBOT_STAGING:-0}" = "1" ]; then
    args+=(--staging)
  fi

  args+=(-d "$primary_domain")
  for d in $all_domains; do
    if [ "$d" != "$primary_domain" ]; then
      args+=(-d "$d")
    fi
  done

  docker compose -f "$COMPOSE_FILE" run --rm --entrypoint certbot certbot "${args[@]}"
}

# Loop over manifest. cert_label is the human-readable label shown by certbot.
while IFS=$'\t' read -r id pdom_var snames_var cert_label _ _; do
  primary_domain="${!pdom_var}"
  server_names="${!snames_var}"
  run_certbot "$cert_label" "$primary_domain" "$server_names"
done < <(sites_iter)

docker compose -f "$COMPOSE_FILE" exec nginx nginx -s reload >/dev/null 2>&1 || true
echo "Done. If nginx was already running, it has been reloaded."

