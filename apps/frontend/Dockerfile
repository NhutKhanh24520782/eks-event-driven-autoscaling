FROM nginx:alpine

COPY rca-lab.html /usr/share/nginx/html/index.html
ARG NGINX_CONFIG=nginx.conf
COPY ${NGINX_CONFIG} /etc/nginx/conf.d/default.conf

EXPOSE 80
