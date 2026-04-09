FROM apache/apisix:3.10.0-debian

USER root

# curl is needed for healthchecks
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Copy template (entrypoint will substitute certs at startup)
COPY apisix.yaml /usr/local/apisix/conf/apisix.yaml.template
COPY config.yaml /usr/local/apisix/conf/config.yaml
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 9443

ENTRYPOINT ["/entrypoint.sh"]
