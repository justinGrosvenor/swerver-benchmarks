FROM alpine:3.19 AS builder

# Install Zig to compile the reference server using the standard library.
ARG ZIG_VERSION=0.13.0
ARG ZIG_ARCH=aarch64
RUN apk add --no-cache curl xz && \
    curl -L "https://ziglang.org/download/${ZIG_VERSION}/zig-linux-${ZIG_ARCH}-${ZIG_VERSION}.tar.xz" | tar -xJ && \
    mv zig-linux-${ZIG_ARCH}-${ZIG_VERSION} /zig

ENV PATH="/zig:${PATH}"

WORKDIR /build
COPY src ./src

# Build the HTTP server using Zig's std lib.
RUN zig build-exe src/main.zig -O ReleaseFast -target aarch64-linux-musl

FROM alpine:3.19
RUN apk add --no-cache ca-certificates wget curl

COPY --from=builder /build/main /usr/local/bin/http-zig

EXPOSE 8080

CMD ["http-zig"]
