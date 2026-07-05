# Build stage. Debian Trixie (matches the runtime for glibc parity). No OpenSSL
# needed: the benchmark app is h1 plaintext only (see app/build.zig).
FROM debian:trixie-slim AS builder

# Install Zig and build tools.
ARG ZIG_PACKAGE=zig-aarch64-linux-0.16.0
ARG ZIG_URL=https://ziglang.org/download/0.16.0/${ZIG_PACKAGE}.tar.xz
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl xz-utils git ca-certificates && \
    rm -rf /var/lib/apt/lists/* && \
    curl -L "${ZIG_URL}" | tar -xJ && \
    mv "${ZIG_PACKAGE}" /zig
ENV PATH="/zig:${PATH}"

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

# Build the benchmark app (registers /health, /echo, /blob against the harness's
# contract) linked against that swerver library (../swerver).
COPY app /build/app
WORKDIR /build/app
RUN zig build

# Runtime stage.
FROM debian:trixie-slim
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl wget && \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/app/zig-out/bin/swerver-bench /usr/local/bin/swerver-bench
COPY --from=builder /build/git-ref.txt /app/git-ref.txt
COPY config.json /app/config.json

WORKDIR /app
EXPOSE 8080

# Serve the benchmark endpoints (the bare `swerver` engine has no routes and
# would 404 the health check).
CMD ["swerver-bench", "--config", "/app/config.json"]
