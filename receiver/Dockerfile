FROM debian:bookworm-slim AS build

ARG UXPLAY_VERSION=1.74

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        cmake \
        curl \
        libgstreamer-plugins-base1.0-dev \
        libgstreamer1.0-dev \
        libplist-dev \
        libssl-dev \
        pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src/uxplay

RUN curl -fsSL --retry 3 --retry-delay 2 \
      "https://github.com/FDH2/UxPlay/archive/refs/tags/v${UXPLAY_VERSION}.tar.gz" \
    | tar -xz --strip-components=1

RUN cmake -S . -B build \
      -DCMAKE_BUILD_TYPE=Release \
      -DNO_MARCH_NATIVE=ON \
      -DNO_X11_DEPS=ON \
    && cmake --build build --parallel "$(nproc)" \
    && cmake --install build

FROM debian:bookworm-slim

ARG UXPLAY_VERSION=1.74

ENV DEBIAN_FRONTEND=noninteractive \
    UXPLAY_VERSION=${UXPLAY_VERSION}

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        gstreamer1.0-libav \
        gstreamer1.0-plugins-bad \
        gstreamer1.0-plugins-base \
        gstreamer1.0-plugins-good \
        gstreamer1.0-tools \
        jq \
        libplist3 \
        libssl3 \
        procps \
        tzdata \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /usr/local/bin/uxplay /usr/local/bin/uxplay
COPY receiver/entrypoint.sh /usr/local/bin/castbridge-receiver
RUN chmod 0755 /usr/local/bin/castbridge-receiver

ENTRYPOINT ["/usr/local/bin/castbridge-receiver"]
