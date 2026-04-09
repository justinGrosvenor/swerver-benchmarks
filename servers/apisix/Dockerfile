FROM apache/apisix:3.10.0-debian

USER root

# curl is needed for healthchecks
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

COPY apisix.yaml /usr/local/apisix/conf/apisix.yaml
COPY config.yaml /usr/local/apisix/conf/config.yaml

EXPOSE 8080

# Initialize then run openresty in foreground (apisix start would daemonize)
CMD ["sh", "-c", "/usr/bin/apisix init && exec /usr/local/openresty/bin/openresty -p /usr/local/apisix -g 'daemon off;'"]
