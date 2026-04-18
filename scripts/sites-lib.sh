#!/usr/bin/env bash
# scripts/sites-lib.sh — manifest helpers for host scripts.
#
# Source me from issue-certificates.sh and deploy-one-db.sh.
# Requires bash 4+ (indirect expansion) and mikefarah/yq v4+.
#
# Usage:
#   . "$SCRIPT_DIR/scripts/sites-lib.sh"
#   while IFS=$'\t' read -r id pdom_var snames_var cert_label priority health; do
#     ...
#   done < <(sites_iter)

# Resolve sites.yaml relative to this script unless overridden.
SITES_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITES_YAML="${SITES_YAML:-$SITES_LIB_DIR/../sites.yaml}"

ensure_yq() {
  if ! command -v yq >/dev/null 2>&1; then
    echo "ERROR: 'yq' (https://github.com/mikefarah/yq) is required." >&2
    echo "  Debian/Ubuntu: sudo wget -qO /usr/local/bin/yq \\" >&2
    echo "    https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 && \\" >&2
    echo "    sudo chmod +x /usr/local/bin/yq" >&2
    echo "  macOS: brew install yq" >&2
    exit 1
  fi
  if [ ! -f "$SITES_YAML" ]; then
    echo "ERROR: manifest not found: $SITES_YAML" >&2
    exit 1
  fi
}

# TSV: id, primary_domain_var, server_names_var, cert_label, priority, health_path
sites_iter() {
  ensure_yq
  yq -r '
    .sites
    | sort_by(.priority)
    | .[]
    | [ .id, .domain.primary_var, .domain.server_names_var,
        (.cert_label // .id), (.priority|tostring), (.health_path // "") ]
    | @tsv
  ' "$SITES_YAML"
}

# TSV: id, db_var, user_var, password_var (only sites with db)
sites_with_db() {
  ensure_yq
  yq -r '
    .sites[] | select(.db) |
    [ .id, .db.db_var, .db.user_var, .db.password_var ] | @tsv
  ' "$SITES_YAML"
}

# Newline-separated unique service names across all sites.
sites_compose_services() {
  ensure_yq
  yq -r '.sites[] | (.compose_services // []) | .[]' "$SITES_YAML" | awk 'NF && !seen[$0]++'
}

# TSV: id, primary_domain_value, health_path (only sites with health_path)
# Resolves the *_PRIMARY_DOMAIN env var here (dies if unset).
sites_with_health() {
  ensure_yq
  while IFS=$'\t' read -r id pdom_var _ _ _ health; do
    [ -n "$health" ] || continue
    pdom_value="${!pdom_var-}"
    if [ -z "$pdom_value" ]; then
      echo "ERROR: $pdom_var is unset (required for site '$id')" >&2
      exit 1
    fi
    printf '%s\t%s\t%s\n' "$id" "$pdom_value" "$health"
  done < <(sites_iter)
}

# Newline-separated env-var names referenced by the manifest (PRIMARY_DOMAIN + SERVER_NAMES).
# Used by callers that need to assert presence before doing work.
sites_required_env_vars() {
  ensure_yq
  yq -r '
    .sites[] |
    [ .domain.primary_var, .domain.server_names_var ] | .[]
  ' "$SITES_YAML" | awk 'NF && !seen[$0]++'
}

# Bash indirect-expansion convenience: prints the value of the variable whose name is $1.
indirect() { printf '%s' "${!1-}"; }


