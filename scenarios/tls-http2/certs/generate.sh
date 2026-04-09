#!/bin/bash
# Generate self-signed certificates for TLS benchmarks
set -e
cd "$(dirname "$0")"

if [ -f server.crt ] && [ -f server.key ]; then
    echo "Certificates already exist, skipping generation"
    exit 0
fi

echo "Generating self-signed certificate..."
openssl req -x509 -newkey rsa:2048 \
    -keyout server.key \
    -out server.crt \
    -days 365 \
    -nodes \
    -subj "/CN=benchmark.local" \
    -addext "subjectAltName=DNS:benchmark.local,DNS:localhost,DNS:swerver,DNS:nginx,DNS:actix" \
    2>/dev/null

echo "Generated: server.crt, server.key"
