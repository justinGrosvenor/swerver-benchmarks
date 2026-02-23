FROM openresty/openresty:alpine

# Provide benchmarking utilities used in health checks.
RUN apk add --no-cache curl wget

# Remove default config
RUN rm -f /etc/nginx/conf.d/default.conf /usr/local/openresty/nginx/conf/nginx.conf

# Copy custom config
COPY config/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf

# Create benchmark response files
RUN mkdir -p /var/www/html && \
    echo -n '{"status":"ok"}' > /var/www/html/echo.json && \
    dd if=/dev/zero of=/var/www/html/blob.bin bs=8K count=1 2>/dev/null

EXPOSE 8080

CMD ["openresty", "-g", "daemon off;"]
