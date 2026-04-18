FROM nginx:1.27-alpine

# gettext: envsubst (template rendering)
# yq:      manifest-driven config generation (sites.yaml)
RUN apk add --no-cache gettext yq

COPY nginx.conf /etc/nginx/nginx.conf
COPY snippets /etc/nginx/snippets
COPY templates /etc/nginx/templates
COPY static /srv/errors
COPY start.sh /usr/local/bin/start.sh

RUN chmod +x /usr/local/bin/start.sh

# sites.yaml is bind-mounted by docker-compose.yaml (so editing it doesn't
# require rebuilding the image).
ENV SITES_YAML=/etc/web-folders/sites.yaml

CMD ["/usr/local/bin/start.sh"]

