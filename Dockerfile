FROM alpine:3.24 AS hev-socks5-build

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

ARG HEV_SOCKS5_VERSION=2.13.1
ARG HEV_SOCKS5_SHA256=aecff4c35d7ffa6458ff55512b04d00c1d102ddc3fbee466534a9b1876022da4

# Alpine package revisions intentionally follow the selected stable branch.
# hadolint ignore=DL3018
RUN apk add --no-cache build-base curl xz \
    && curl -fsSL "https://github.com/heiher/hev-socks5-server/releases/download/${HEV_SOCKS5_VERSION}/hev-socks5-server-${HEV_SOCKS5_VERSION}.tar.xz" -o /tmp/hev-socks5-server.tar.xz \
    && echo "${HEV_SOCKS5_SHA256}  /tmp/hev-socks5-server.tar.xz" | sha256sum -c - \
    && mkdir -p /tmp/hev-socks5-server \
    && tar -xJf /tmp/hev-socks5-server.tar.xz -C /tmp/hev-socks5-server --strip-components=1 \
    && make -C /tmp/hev-socks5-server ENABLE_STATIC=1 -j2

FROM alpine:3.24

ARG VERSION=dev
ARG REVISION=unknown
ARG SOURCE_URL=""

LABEL org.opencontainers.image.title="SSH TUN Gateway" \
      org.opencontainers.image.description="IPv4 gateway and SOCKS5 proxy over an OpenSSH TUN tunnel" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.source="${SOURCE_URL}" \
      org.opencontainers.image.licenses="MIT"

# Alpine package revisions intentionally follow the selected stable branch.
# hadolint ignore=DL3018
RUN apk add --no-cache \
    ca-certificates \
    iproute2 \
    iptables \
    iptables-legacy \
    openssh-client \
    su-exec \
    tini

RUN addgroup -S socks \
    && adduser -S -D -H -G socks socks

COPY --from=hev-socks5-build /tmp/hev-socks5-server/bin/hev-socks5-server /usr/local/bin/hev-socks5-server
COPY --from=hev-socks5-build /tmp/hev-socks5-server/LICENSE /usr/share/licenses/hev-socks5-server/LICENSE
COPY --chmod=0755 entrypoint.sh /usr/local/sbin/ssh-tun-gateway-entrypoint

EXPOSE 1080/tcp
STOPSIGNAL SIGTERM

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/sbin/ssh-tun-gateway-entrypoint"]
