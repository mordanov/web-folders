#!/bin/sh
set -eu

: "${MAINPAGE_PRIMARY_DOMAIN:?Missing MAINPAGE_PRIMARY_DOMAIN}"

# Render a runtime index.html from template placeholders.
envsubst '${MAINPAGE_PRIMARY_DOMAIN}' < /usr/share/nginx/html/index.html > /tmp/index.html
mv /tmp/index.html /usr/share/nginx/html/index.html

exec nginx -g 'daemon off;'

