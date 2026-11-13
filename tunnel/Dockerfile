# warp-tunnel: a network namespace whose only way out is Cloudflare WARP, over MASQUE
# (HTTP/3, run by usque) or WireGuard (kernel module, or wireguard-go as a fallback). Other
# containers join it with `network_mode: service:<this>`. Other projects can also extend it
# with `FROM` plus a hooks file; see README "Reusing the tunnel".
FROM alpine:3.22@sha256:49340b346798875b5592e5d420241f2f9cfba5f47e62ebb1446a1b34734e898f
ARG USQUE_VERSION=4.2.1
ARG WGCF_VERSION=2.3.1
ARG TARGETARCH
# Expected SHA-256 of each release binary, pinned here rather than trusted from the release's
# own checksums.txt (matches GitHub's upload-time asset digests). Update with the versions above.
ARG USQUE_SHA256_amd64=4117e20695078af9c11edecd1a826c009bbc7ea0b7f64458612b4198910bc313
ARG USQUE_SHA256_arm64=c88b061c2a567f30813d7505637d1fb6fe7ec5898b5b61fd05122409fa5ad925
ARG WGCF_SHA256_amd64=4fb7a136aa470ece11d17949c7db07b040ec9c604742dc8680bcf1889f85d0c8
ARG WGCF_SHA256_arm64=710ab2d8ac145d81a4cf0c11bdb0e05914f77ae2a45f67b87e718d84b4cb7301

RUN apk add --no-cache nftables iproute2 curl jq ca-certificates wireguard-tools-wg wireguard-go

# Official usque (MASQUE client) and wgcf (WireGuard registration) release binaries, verified
# against the hashes pinned above.
RUN set -eu; cd /tmp; \
    arch="${TARGETARCH:-$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')}"; \
    case "$arch" in \
      amd64) usque_sha="$USQUE_SHA256_amd64" wgcf_sha="$WGCF_SHA256_amd64" ;; \
      arm64) usque_sha="$USQUE_SHA256_arm64" wgcf_sha="$WGCF_SHA256_arm64" ;; \
      *) echo "unsupported arch $arch" >&2; exit 1 ;; \
    esac; \
    f="usque_${USQUE_VERSION}_linux_${arch}.zip"; \
    wget -q "https://github.com/Diniboy1123/usque/releases/download/v${USQUE_VERSION}/$f"; \
    echo "$usque_sha  $f" | sha256sum -c -; \
    unzip -q "$f" usque -d /usr/local/bin; \
    rm -f /tmp/*; \
    f="wgcf_${WGCF_VERSION}_linux_${arch}"; \
    wget -q "https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VERSION}/$f"; \
    echo "$wgcf_sha  $f" | sha256sum -c -; \
    install -m 755 "$f" /usr/local/bin/wgcf; \
    rm -f /tmp/*

COPY lib.sh entrypoint.sh on-connect.sh healthcheck.sh /usr/local/lib/warp-tunnel/
RUN chmod +x /usr/local/lib/warp-tunnel/*.sh && mkdir -p /etc/warp-tunnel
ENTRYPOINT ["/usr/local/lib/warp-tunnel/entrypoint.sh"]
HEALTHCHECK --interval=10s --timeout=8s --start-period=20s --retries=2 \
  CMD ["/usr/local/lib/warp-tunnel/healthcheck.sh"]
