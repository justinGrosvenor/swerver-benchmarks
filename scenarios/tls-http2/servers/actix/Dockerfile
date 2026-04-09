# Build stage
FROM rust:1.88 AS builder
WORKDIR /build
COPY Cargo.toml .
COPY src/ src/
RUN cargo build --release

# Runtime stage
FROM debian:bookworm-slim
RUN apt-get update && \
    apt-get install -y ca-certificates curl && \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/target/release/actix-bench-tls /usr/local/bin/actix-bench-tls
WORKDIR /app
EXPOSE 8443
CMD ["actix-bench-tls"]
