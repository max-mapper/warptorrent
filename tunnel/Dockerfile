# warp-tunnel: a network namespace whose only way out is Cloudflare WARP, over MASQUE
# (HTTP/3, run by usque) or WireGuard (kernel module, or wireguard-go as a fallback). Other
# containers join it with `network_mode: service:<this>`. Other projects can also extend it
# with `FROM` plus a hooks file; see README "Reusing the tunnel".
FROM alpine:3.22
ARG USQUE_VERSION=4.2.1
ARG WGCF_VERSION=2.3.1
ARG TARGETARCH

RUN apk add --no-cache nftables iproute2 curl jq ca-certificates wireguard-tools-wg wireguard-go

# Official usque (MASQUE client) and wgcf (WireGuard registration) release binaries,
# checksum-verified.
RUN set -eu; cd /tmp; \
    arch="${TARGETARCH:-$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')}"; \
    f="usque_${USQUE_VERSION}_linux_${arch}.zip"; \
    base="https://github.com/Diniboy1123/usque/releases/download/v${USQUE_VERSION}"; \
    wget -q "$base/$f" "$base/checksums.txt"; \
    grep " $f\$" checksums.txt | sha256sum -c -; \
    unzip -q "$f" usque -d /usr/local/bin; \
    rm -f /tmp/*; \
    f="wgcf_${WGCF_VERSION}_linux_${arch}"; \
    base="https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VERSION}"; \
    wget -q "$base/$f" "$base/checksums.txt"; \
    grep " $f\$" checksums.txt | sha256sum -c -; \
    install -m 755 "$f" /usr/local/bin/wgcf; \
    rm -f /tmp/*

COPY lib.sh entrypoint.sh on-connect.sh healthcheck.sh /usr/local/lib/warp-tunnel/
RUN chmod +x /usr/local/lib/warp-tunnel/*.sh && mkdir -p /etc/warp-tunnel
ENTRYPOINT ["/usr/local/lib/warp-tunnel/entrypoint.sh"]
HEALTHCHECK --interval=10s --timeout=8s --start-period=20s --retries=2 \
  CMD ["/usr/local/lib/warp-tunnel/healthcheck.sh"]
