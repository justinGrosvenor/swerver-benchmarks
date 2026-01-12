FROM rust:1.85 AS builder

WORKDIR /app
COPY Cargo.toml .
COPY src ./src

# Build release binary to keep runtime image fast.
RUN cargo build --release

FROM debian:bookworm-slim
RUN apt-get update && \
    apt-get install -y ca-certificates curl wget && \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /app/target/release/actix-bench /usr/local/bin/actix-bench

EXPOSE 8080
CMD ["actix-bench"]
