# Build stage
FROM debian:bookworm-slim AS builder

# Install Zig and build tools
ARG ZIG_PACKAGE=zig-aarch64-linux-0.16.0-dev.2637+6a9510c0e
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl xz-utils git libssl-dev ca-certificates && \
    rm -rf /var/lib/apt/lists/* && \
    curl -L "https://ziglang.org/builds/${ZIG_PACKAGE}.tar.xz" | tar -xJ && \
    mv "${ZIG_PACKAGE}" /zig

ENV PATH="/zig:${PATH}"

# Clone swerver (or use local copy if provided)
ARG SWERVER_REPO=https://github.com/justin/swerver.git
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

# Build with release optimizations
WORKDIR /build/swerver
RUN zig build -Doptimize=ReleaseFast 2>&1 || \
    zig build -Doptimize=ReleaseSafe 2>&1 || \
    zig build

# Runtime stage
FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y ca-certificates curl wget && \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/swerver/zig-out/bin/swerver /usr/local/bin/swerver
COPY --from=builder /build/git-ref.txt /app/git-ref.txt

WORKDIR /app
EXPOSE 8080

# Benchmark endpoints available:
# GET /health - minimal health check (empty 200)
# GET /echo   - returns {"status":"ok"}
# POST /echo  - echoes request body
# GET /blob   - returns 1MB response
CMD ["swerver"]
