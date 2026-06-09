# Build stage. We use Debian Trixie because it ships OpenSSL 3.5+,
# which has SSL_set_quic_tls_cbs / SSL_set_quic_tls_transport_params —
# the QUIC TLS callback API swerver's HTTP/3 stack uses. Bookworm's
# OpenSSL 3.0.x doesn't have those symbols and the link fails when
# h3 is enabled. Bookworm still works for h1-only builds, but Trixie
# works for both, so we use it everywhere.
FROM debian:trixie-slim AS builder

# Install Zig and build tools
ARG ZIG_PACKAGE=zig-aarch64-linux-0.16.0
ARG ZIG_URL=https://ziglang.org/download/0.16.0/${ZIG_PACKAGE}.tar.xz
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl xz-utils git libssl-dev zlib1g-dev ca-certificates && \
    rm -rf /var/lib/apt/lists/* && \
    curl -L "${ZIG_URL}" | tar -xJ && \
    mv "${ZIG_PACKAGE}" /zig

ENV PATH="/zig:${PATH}"

# Clone swerver (or use local copy if provided)
ARG SWERVER_REPO=https://github.com/justinGrosvenor/swerver.git
ARG SWERVER_REF=main
ARG SWERVER_LOCAL_PATH=

WORKDIR /build

# If local path provided, copy from context; otherwise clone from git
RUN if [ -n "${SWERVER_LOCAL_PATH}" ]; then \
        echo "Using local swerver from build context"; \
    else \
        git clone ${SWERVER_REPO} swerver && \
        cd swerver && \
        git checkout ${SWERVER_REF} && \
        git rev-parse HEAD > /build/git-ref.txt; \
    fi

# Copy local swerver if provided via build context
COPY swerver-src* /build/swerver-local/
RUN if [ -d "/build/swerver-local" ] && [ "$(ls -A /build/swerver-local 2>/dev/null)" ]; then \
        rm -rf /build/swerver && \
        mv /build/swerver-local /build/swerver && \
        echo "local" > /build/git-ref.txt; \
    fi

# Build with release optimizations.
# Fail loudly on build error rather than silently falling back to a slower
# optimization mode (which would produce misleading benchmark numbers).
WORKDIR /build/swerver
ARG ZIG_BUILD_FLAGS=""
RUN zig build -Doptimize=ReleaseFast ${ZIG_BUILD_FLAGS}

# Runtime stage — Trixie too, so libssl.so.3 matches the build target.
FROM debian:trixie-slim

RUN apt-get update && \
    apt-get install -y ca-certificates curl wget && \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/swerver/zig-out/bin/swerver /usr/local/bin/swerver
COPY --from=builder /build/git-ref.txt /app/git-ref.txt

WORKDIR /app

# Generate static test files for H2 file-serving benchmarks
RUN mkdir -p /app/static && \
    dd if=/dev/urandom of=/app/static/small.txt bs=1024 count=1 2>/dev/null && \
    dd if=/dev/urandom of=/app/static/medium.css bs=1024 count=32 2>/dev/null && \
    dd if=/dev/urandom of=/app/static/large.js bs=1024 count=128 2>/dev/null && \
    dd if=/dev/urandom of=/app/static/image.bin bs=1024 count=512 2>/dev/null

EXPOSE 8080

CMD ["swerver"]
