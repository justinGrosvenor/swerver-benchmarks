# h2load with HTTP/3 support
# k6 doesn't speak h3, so we need a different load generator. We use
# nghttp2's h2load (the de-facto h2/h3 benchmark tool), built from source
# against ngtcp2 + nghttp3 + OpenSSL 3.5+ (Debian Trixie's libssl-dev).
#
# Output is exec-only — the scenario run script invokes h2load directly:
#   docker run --rm <image> --alpn-list=h3 -c100 -n50000 https://swerver:9443/echo

FROM debian:trixie-slim AS builder

ARG NGHTTP2_VERSION=v1.68.1
ARG NGHTTP3_VERSION=v1.15.0
ARG NGTCP2_VERSION=v1.22.0

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git \
        build-essential cmake ninja-build pkg-config \
        libssl-dev libev-dev zlib1g-dev libbrotli-dev libc-ares-dev \
        autoconf automake libtool && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Build nghttp3
RUN git clone --depth=1 --branch ${NGHTTP3_VERSION} https://github.com/ngtcp2/nghttp3 && \
    cd nghttp3 && git submodule update --init && \
    autoreconf -i && ./configure --prefix=/usr/local --enable-lib-only && \
    make -j"$(nproc)" install

# Build ngtcp2 against system OpenSSL (3.5+ on Debian Trixie has the QUIC
# TLS callback API).
RUN git clone --depth=1 --branch ${NGTCP2_VERSION} https://github.com/ngtcp2/ngtcp2 && \
    cd ngtcp2 && git submodule update --init && \
    autoreconf -i && \
    ./configure --prefix=/usr/local --with-openssl --enable-lib-only && \
    make -j"$(nproc)" install

# Build nghttp2 + h2load with HTTP/3 enabled. We let cmake `install` lay
# everything down (libnghttp2 + h2load) into /usr/local so the runtime
# stage can copy a single tree.
RUN git clone --depth=1 --branch ${NGHTTP2_VERSION} https://github.com/nghttp2/nghttp2 && \
    cd nghttp2 && git submodule update --init && \
    mkdir build && cd build && \
    cmake -GNinja .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DENABLE_HTTP3=ON \
        -DCMAKE_PREFIX_PATH=/usr/local && \
    ninja && ninja install

# ---- Runtime stage ----
FROM debian:trixie-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates libssl3 libev4 libbrotli1 libc-ares2 zlib1g \
        libxml2 libjemalloc2 libsystemd0 && \
    rm -rf /var/lib/apt/lists/*

# Copy h2load + every shared lib it links against (libnghttp2,
# libnghttp3, libngtcp2, libngtcp2_crypto_ossl). Bringing the whole
# /usr/local from the builder is the simplest way to get all of them
# along with their .so symlinks.
COPY --from=builder /usr/local /usr/local
RUN ldconfig

ENTRYPOINT ["h2load"]
