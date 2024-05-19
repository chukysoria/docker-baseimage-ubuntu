# syntax=docker/dockerfile:1

ARG BUILD_FROM=alpine:3.19.1

FROM ${BUILD_FROM} as rootfs-stage

# environment
ARG BUILD_ARCH
ARG BUILD_EXT_RELEASE=noble

# install packages
RUN \
  apk add --no-cache \
    bash \
    curl \
    tzdata \
    xz

# grab base tarball
RUN <<EOF
  if [[ $BUILD_ARCH == "armv7" ]]; then
    UBUNTU_ARCH=armhf
  elif [[ $BUILD_ARCH == "aarch64" ]]; then
    UBUNTU_ARCH=arm64
  elif [[ $BUILD_ARCH == "x86_64" ]]; then
    UBUNTU_ARCH=amd64
  fi
  mkdir /root-out
  curl -o \
    /rootfs.tar.gz -L \
    https://partner-images.canonical.com/core/${BUILD_EXT_RELEASE}/20230626/ubuntu-${BUILD_EXT_RELEASE}-core-cloudimg-${UBUNTU_ARCH}-root.tar.gz
  tar xf \
    /rootfs.tar.gz -C \
    /root-out
  rm -rf \
    /root-out/var/log/*
EOF

# set version for s6 overlay
ARG S6_OVERLAY_VERSION="3.1.6.2"

# add s6 overlay
ADD https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz /tmp
RUN tar -C /root-out -Jxpf /tmp/s6-overlay-noarch.tar.xz
RUN <<EOF
  if [[ $BUILD_ARCH == "armv7" ]]; then
    S6_OVERLAY_ARCH=armhf
  else
    S6_OVERLAY_ARCH=$BUILD_ARCH
  fi
  curl -L -o /tmp/s6-overlay-${S6_OVERLAY_ARCH}.tar.xz https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${S6_OVERLAY_ARCH}.tar.xz
  tar -C /root-out -Jxpf /tmp/s6-overlay-${S6_OVERLAY_ARCH}.tar.xz
EOF

# add s6 optional symlinks
ADD https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-symlinks-noarch.tar.xz /tmp
RUN tar -C /root-out -Jxpf /tmp/s6-overlay-symlinks-noarch.tar.xz
ADD https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-symlinks-arch.tar.xz /tmp
RUN tar -C /root-out -Jxpf /tmp/s6-overlay-symlinks-arch.tar.xz

# Runtime stage
FROM scratch
COPY --from=rootfs-stage /root-out/ /
ARG BUILD_ARCH
ARG BUILD_DATE
ARG VERSION
ARG MODS_VERSION="v3"
ARG PKG_INST_VERSION="v1"
LABEL build_version="Carlosserver.io version:- ${VERSION} Build-date:- ${BUILD_DATE}"
LABEL maintainer="Chukysoria"

ADD --chmod=744 "https://raw.githubusercontent.com/linuxserver/docker-mods/mod-scripts/docker-mods.${MODS_VERSION}" "/docker-mods"
ADD --chmod=744 "https://raw.githubusercontent.com/linuxserver/docker-mods/mod-scripts/package-install.${PKG_INST_VERSION}" "/etc/s6-overlay/s6-rc.d/init-mods-package-install/run"

# set environment variables
ARG DEBIAN_FRONTEND="noninteractive"
ENV HOME="/root" \
  LANGUAGE="en_US.UTF-8" \
  LANG="en_US.UTF-8" \
  TERM="xterm" \
  S6_CMD_WAIT_FOR_SERVICES_MAXTIME="0" \
  S6_VERBOSITY=1 \
  S6_STAGE2_HOOK=/docker-mods \
  VIRTUAL_ENV=/lsiopy \
  PATH="/lsiopy/bin:$PATH"

# copy sources
COPY sources.list.${BUILD_ARCH} /etc/apt/sources.list

RUN \
  echo "**** Ripped from Ubuntu Docker Logic ****" && \
  set -xe && \
  echo '#!/bin/sh' \
    > /usr/sbin/policy-rc.d && \
  echo 'exit 101' \
    >> /usr/sbin/policy-rc.d && \
  chmod +x \
    /usr/sbin/policy-rc.d && \
  dpkg-divert --local --rename --add /sbin/initctl && \
  cp -a \
    /usr/sbin/policy-rc.d \
    /sbin/initctl && \
  sed -i \
    's/^exit.*/exit 0/' \
    /sbin/initctl && \
  echo 'force-unsafe-io' \
    > /etc/dpkg/dpkg.cfg.d/docker-apt-speedup && \
  echo 'DPkg::Post-Invoke { "rm -f /var/cache/apt/archives/*.deb /var/cache/apt/archives/partial/*.deb /var/cache/apt/*.bin || true"; };' \
    > /etc/apt/apt.conf.d/docker-clean && \
  echo 'APT::Update::Post-Invoke { "rm -f /var/cache/apt/archives/*.deb /var/cache/apt/archives/partial/*.deb /var/cache/apt/*.bin || true"; };' \
    >> /etc/apt/apt.conf.d/docker-clean && \
  echo 'Dir::Cache::pkgcache ""; Dir::Cache::srcpkgcache "";' \
    >> /etc/apt/apt.conf.d/docker-clean && \
  echo 'Acquire::Languages "none";' \
    > /etc/apt/apt.conf.d/docker-no-languages && \
  echo 'Acquire::GzipIndexes "true"; Acquire::CompressionTypes::Order:: "gz";' \
    > /etc/apt/apt.conf.d/docker-gzip-indexes && \
  echo 'Apt::AutoRemove::SuggestsImportant "false";' \
    > /etc/apt/apt.conf.d/docker-autoremove-suggests && \
  mkdir -p /run/systemd && \
  echo 'docker' \
    > /run/systemd/container && \
  echo "**** install apt-utils and locales ****" && \
  apt-get update && \
  apt-get install -y \
    apt-utils \
    locales && \
  echo "**** install packages ****" && \
  apt-get install -y \
    cron \
    curl=7.81.0-1ubuntu1.16 \
    gnupg \
    jq=1.6-2.1ubuntu3 \
    netcat=1.218-4ubuntu1 \
    tzdata=2024a-0ubuntu0.22.04 && \
  echo "**** generate locale ****" && \
  locale-gen en_US.UTF-8 && \
  echo "**** create abc user and make our folders ****" && \
  useradd -u 911 -U -d /config -s /bin/false abc && \
  usermod -G users abc && \
  mkdir -p \
    /app \
    /config \
    /defaults \
    /lsiopy && \
  echo "**** add qemu ****" && \
  curl -o \
  /usr/bin/qemu-arm-static -L \
    "https://lsio-ci.ams3.digitaloceanspaces.com/qemu-arm-static" && \
  chmod +x /usr/bin/qemu-arm-static && \
  echo "**** cleanup ****" && \
  apt-get autoremove && \
  apt-get clean && \
  rm -rf \
    /tmp/* \
    /var/lib/apt/lists/* \
    /var/tmp/* \
    /var/log/*

# add local files
COPY root/ /

ENTRYPOINT ["/init"]
