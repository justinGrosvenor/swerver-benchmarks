FROM nginx:1.25-alpine

# Provide benchmarking utilities used in health checks.
RUN apk add --no-cache curl wget

# Remove default config
RUN rm /etc/nginx/conf.d/default.conf

# Copy custom config
COPY config/nginx.conf /etc/nginx/nginx.conf

# Create benchmark response files
RUN mkdir -p /var/www/html && \
    echo -n '{"status":"ok"}' > /var/www/html/echo.json && \
    dd if=/dev/zero of=/var/www/html/blob.bin bs=8K count=1 2>/dev/null

EXPOSE 8080

CMD ["nginx", "-g", "daemon off;"]
