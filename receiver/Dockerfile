ARG DEBIAN_BASE_IMAGE=debian:bookworm-slim
FROM ${DEBIAN_BASE_IMAGE} AS build

ARG UXPLAY_VERSION=1.73.7
ARG UXPLAY_ARCHIVE=vendor/uxplay/uxplay-v1.73.7.tar.gz
ARG DEBIAN_MIRROR=
ARG DEBIAN_SECURITY_MIRROR=

ENV DEBIAN_FRONTEND=noninteractive

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    set -eux; \
    rm -f /etc/apt/apt.conf.d/docker-clean; \
    if [ -n "${DEBIAN_MIRROR}" ]; then \
      if [ -f /etc/apt/sources.list.d/debian.sources ]; then \
        sed -i \
          -e "s|http://deb.debian.org/debian-security|${DEBIAN_SECURITY_MIRROR:-${DEBIAN_MIRROR}-security}|g" \
          -e "s|https://deb.debian.org/debian-security|${DEBIAN_SECURITY_MIRROR:-${DEBIAN_MIRROR}-security}|g" \
          -e "s|http://deb.debian.org/debian|${DEBIAN_MIRROR}|g" \
          -e "s|https://deb.debian.org/debian|${DEBIAN_MIRROR}|g" \
          /etc/apt/sources.list.d/debian.sources; \
      elif [ -f /etc/apt/sources.list ]; then \
        sed -i \
          -e "s|http://deb.debian.org/debian-security|${DEBIAN_SECURITY_MIRROR:-${DEBIAN_MIRROR}-security}|g" \
          -e "s|https://deb.debian.org/debian-security|${DEBIAN_SECURITY_MIRROR:-${DEBIAN_MIRROR}-security}|g" \
          -e "s|http://deb.debian.org/debian|${DEBIAN_MIRROR}|g" \
          -e "s|https://deb.debian.org/debian|${DEBIAN_MIRROR}|g" \
          /etc/apt/sources.list; \
      fi; \
    fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        cmake \
        gzip \
        libavahi-compat-libdnssd-dev \
        libgstreamer-plugins-base1.0-dev \
        libgstreamer1.0-dev \
        libplist-dev \
        libssl-dev \
        pkg-config

WORKDIR /src/uxplay
COPY ${UXPLAY_ARCHIVE} /tmp/uxplay.tar.gz
RUN set -eux; \
    tar -xzf /tmp/uxplay.tar.gz --strip-components=1; \
    rm -f /tmp/uxplay.tar.gz; \
    test -f CMakeLists.txt

RUN cmake -S . -B build \
      -DCMAKE_BUILD_TYPE=Release \
      -DNO_MARCH_NATIVE=ON \
      -DNO_X11_DEPS=ON \
    && cmake --build build --parallel "$(nproc)" \
    && cmake --install build

FROM ${DEBIAN_BASE_IMAGE}

ARG UXPLAY_VERSION=1.73.7
ARG DEBIAN_MIRROR=
ARG DEBIAN_SECURITY_MIRROR=

ENV DEBIAN_FRONTEND=noninteractive \
    UXPLAY_VERSION=${UXPLAY_VERSION}

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    set -eux; \
    rm -f /etc/apt/apt.conf.d/docker-clean; \
    if [ -n "${DEBIAN_MIRROR}" ]; then \
      if [ -f /etc/apt/sources.list.d/debian.sources ]; then \
        sed -i \
          -e "s|http://deb.debian.org/debian-security|${DEBIAN_SECURITY_MIRROR:-${DEBIAN_MIRROR}-security}|g" \
          -e "s|https://deb.debian.org/debian-security|${DEBIAN_SECURITY_MIRROR:-${DEBIAN_MIRROR}-security}|g" \
          -e "s|http://deb.debian.org/debian|${DEBIAN_MIRROR}|g" \
          -e "s|https://deb.debian.org/debian|${DEBIAN_MIRROR}|g" \
          /etc/apt/sources.list.d/debian.sources; \
      elif [ -f /etc/apt/sources.list ]; then \
        sed -i \
          -e "s|http://deb.debian.org/debian-security|${DEBIAN_SECURITY_MIRROR:-${DEBIAN_MIRROR}-security}|g" \
          -e "s|https://deb.debian.org/debian-security|${DEBIAN_SECURITY_MIRROR:-${DEBIAN_MIRROR}-security}|g" \
          -e "s|http://deb.debian.org/debian|${DEBIAN_MIRROR}|g" \
          -e "s|https://deb.debian.org/debian|${DEBIAN_MIRROR}|g" \
          /etc/apt/sources.list; \
      fi; \
    fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        avahi-daemon \
        avahi-utils \
        bash \
        ca-certificates \
        dbus \
        gstreamer1.0-libav \
        gstreamer1.0-plugins-bad \
        gstreamer1.0-plugins-base \
        gstreamer1.0-plugins-good \
        gstreamer1.0-tools \
        jq \
        libavahi-compat-libdnssd1 \
        libplist3 \
        libssl3 \
        procps \
        tzdata

COPY --from=build /usr/local/bin/uxplay /usr/local/bin/uxplay
COPY receiver/entrypoint.sh /usr/local/bin/castbridge-receiver
RUN chmod 0755 /usr/local/bin/castbridge-receiver

ENTRYPOINT ["/usr/local/bin/castbridge-receiver"]
