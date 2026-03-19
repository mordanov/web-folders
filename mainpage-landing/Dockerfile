FROM nginx:1.27-alpine

RUN apk add --no-cache gettext

COPY static/ /usr/share/nginx/html/
COPY start.sh /usr/local/bin/start.sh

RUN chmod +x /usr/local/bin/start.sh

CMD ["/usr/local/bin/start.sh"]
