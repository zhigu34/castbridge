ARG DEBIAN_BASE_IMAGE=debian:bookworm-slim
FROM ${DEBIAN_BASE_IMAGE} AS build

ARG UXPLAY_VERSION=1.74
ARG DEBIAN_MIRROR=
ARG DEBIAN_SECURITY_MIRROR=
ARG UXPLAY_SOURCE_URL=

ENV DEBIAN_FRONTEND=noninteractive

RUN set -eux; \
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
        curl \
        libgstreamer-plugins-base1.0-dev \
        libgstreamer1.0-dev \
        libplist-dev \
        libssl-dev \
        pkg-config; \
    rm -rf /var/lib/apt/lists/*

WORKDIR /src/uxplay

RUN set -eux; \
    source_url="${UXPLAY_SOURCE_URL:-https://github.com/FDH2/UxPlay/archive/refs/tags/v${UXPLAY_VERSION}.tar.gz}"; \
    curl -fsSL --retry 5 --retry-delay 2 --connect-timeout 15 "${source_url}" \
    | tar -xz --strip-components=1

RUN cmake -S . -B build \
      -DCMAKE_BUILD_TYPE=Release \
      -DNO_MARCH_NATIVE=ON \
      -DNO_X11_DEPS=ON \
    && cmake --build build --parallel "$(nproc)" \
    && cmake --install build

FROM ${DEBIAN_BASE_IMAGE}

ARG UXPLAY_VERSION=1.74
ARG DEBIAN_MIRROR=
ARG DEBIAN_SECURITY_MIRROR=

ENV DEBIAN_FRONTEND=noninteractive \
    UXPLAY_VERSION=${UXPLAY_VERSION}

RUN set -eux; \
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
        tzdata; \
    rm -rf /var/lib/apt/lists/*

COPY --from=build /usr/local/bin/uxplay /usr/local/bin/uxplay
COPY receiver/entrypoint.sh /usr/local/bin/castbridge-receiver
RUN chmod 0755 /usr/local/bin/castbridge-receiver

ENTRYPOINT ["/usr/local/bin/castbridge-receiver"]
