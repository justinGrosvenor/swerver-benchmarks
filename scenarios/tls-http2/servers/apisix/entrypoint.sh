#!/bin/sh
# Inline the cert/key into apisix.yaml at startup
set -e

CERT_FILE=/certs/server.crt
KEY_FILE=/certs/server.key
TEMPLATE=/usr/local/apisix/conf/apisix.yaml.template
OUTPUT=/usr/local/apisix/conf/apisix.yaml

if [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
    echo "ERROR: certificates not found at $CERT_FILE / $KEY_FILE"
    exit 1
fi

# Read cert and key, indent each line by 6 spaces (YAML block scalar)
CERT_INDENTED=$(sed 's/^/      /' "$CERT_FILE")
KEY_INDENTED=$(sed 's/^/      /' "$KEY_FILE")

# Substitute the placeholders with the cert/key contents
awk -v cert="$CERT_INDENTED" -v key="$KEY_INDENTED" '
    /CERT_PLACEHOLDER/ { print cert; next }
    /KEY_PLACEHOLDER/ { print key; next }
    { print }
' "$TEMPLATE" > "$OUTPUT"

# Initialize APISIX config (generates nginx.conf from templates)
/usr/bin/apisix init

# Run openresty in foreground (apisix start would daemonize)
exec /usr/local/openresty/bin/openresty -p /usr/local/apisix -g "daemon off;"
