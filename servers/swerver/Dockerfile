# Build stage. Debian Trixie ships OpenSSL 3.5+ (SSL_set_quic_tls_cbs / ...),
# the QUIC TLS callback API swerver's HTTP/3 stack needs; Bookworm's 3.0.x lacks
# those symbols and the h3 link fails. Trixie works for h1/h2/h3, so use it.
FROM debian:trixie-slim AS builder

# Zig + build/link deps (OpenSSL for tls/h2/h3, zlib for compression).
ARG ZIG_PACKAGE=zig-aarch64-linux-0.16.0
ARG ZIG_URL=https://ziglang.org/download/0.16.0/${ZIG_PACKAGE}.tar.xz
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        curl xz-utils git ca-certificates libssl-dev zlib1g-dev dpkg-dev pkg-config && \
    rm -rf /var/lib/apt/lists/* && \
    curl -L "${ZIG_URL}" | tar -xJ && \
    mv "${ZIG_PACKAGE}" /zig
ENV PATH="/zig:${PATH}"

# Zig's linker looks for libssl/libcrypto under /usr/lib; symlink the multiarch
# copies so -lssl/-lcrypto resolve.
RUN MULTIARCH=$(dpkg-architecture -qDEB_HOST_MULTIARCH); \
    for lib in libssl.so libcrypto.so; do \
        ln -sf "/usr/lib/${MULTIARCH}/${lib}" "/usr/lib/${lib}"; \
    done

# swerver source selection:
#   - local working tree  -> set USE_LOCAL_SWERVER=1 (the runner rsyncs it into
#     servers/swerver/swerver-src, copied here as /build/swerver-local)
#   - a git ref (default)  -> clone SWERVER_REF (e.g. main, or a tag baseline)
ARG SWERVER_REPO=https://github.com/justinGrosvenor/swerver.git
ARG SWERVER_REF=main
WORKDIR /build

# The glob is a no-op when swerver-src is absent (git-ref mode); when present
# (local mode) it lands the working tree under /build/swerver-local.
COPY swerver-src* /build/swerver-local/
RUN if [ -d /build/swerver-local ] && [ -n "$(ls -A /build/swerver-local 2>/dev/null)" ]; then \
        echo "Using local swerver from build context"; \
        mv /build/swerver-local /build/swerver && echo "local" > /build/git-ref.txt; \
    else \
        rm -rf /build/swerver-local; \
        echo "Cloning swerver ${SWERVER_REF}"; \
        git clone "${SWERVER_REPO}" /build/swerver && \
        cd /build/swerver && git checkout "${SWERVER_REF}" && \
        git rev-parse HEAD > /build/git-ref.txt; \
    fi

# Build the benchmark app (registers /health, /echo, /blob, /plaintext against
# the harness contract; full protocol support) linked against ../swerver.
COPY app /build/app
WORKDIR /build/app
RUN zig build

# Runtime stage.
FROM debian:trixie-slim
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates curl wget libssl3 zlib1g && \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/app/zig-out/bin/swerver /usr/local/bin/swerver
COPY --from=builder /build/git-ref.txt /app/git-ref.txt
COPY config.json /app/config.json

WORKDIR /app

# Static assets for the h2-static-files test (scenario config points static_root
# at /app/static).
RUN mkdir -p /app/static && \
    dd if=/dev/urandom of=/app/static/small.txt  bs=1024 count=1   2>/dev/null && \
    dd if=/dev/urandom of=/app/static/medium.css bs=1024 count=32  2>/dev/null && \
    dd if=/dev/urandom of=/app/static/large.js   bs=1024 count=128 2>/dev/null && \
    dd if=/dev/urandom of=/app/static/image.bin  bs=1024 count=512 2>/dev/null

EXPOSE 8080 8443

# The bench app IS the `swerver` binary here (the bare engine has no routes and
# would 404 the health check). Scenario composes override the config/command.
CMD ["swerver", "--config", "/app/config.json"]
