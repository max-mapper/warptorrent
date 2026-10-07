#!/usr/bin/env bash
# Registers an anonymous free Cloudflare WARP device with wgcf (run inside a throwaway
# container, so nothing gets installed on the host) and converts the WireGuard profile into
# gluetun env vars at config/warp.env. No Cloudflare login or API token is needed.
set -euo pipefail
cd "$(dirname "$0")/.."

WGCF_VERSION="${WGCF_VERSION:-v2.3.0}"
# gluetun needs a literal IP. 162.159.192.1 is what engage.cloudflareclient.com resolves to.
WARP_ENDPOINT_IP="${WARP_ENDPOINT_IP:-162.159.192.1}"
WARP_ENDPOINT_PORT="${WARP_ENDPOINT_PORT:-2408}"

mkdir -p config
chmod 700 config

if [[ ! -f config/wgcf-account.toml ]]; then
  echo "→ registering a new WARP device (accepts Cloudflare's WARP ToS)…"
  wgcf_cmd="register --accept-tos"
else
  echo "→ reusing existing config/wgcf-account.toml"
  wgcf_cmd="update"
fi

# Download the official release binary (checksum-verified) inside a throwaway container.
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "$PWD/config:/work" -w /work alpine:latest sh -euc "
    v=${WGCF_VERSION#v}
    case \$(uname -m) in aarch64) arch=arm64 ;; x86_64) arch=amd64 ;; *) echo unsupported arch >&2; exit 1 ;; esac
    bin=wgcf_\${v}_linux_\${arch}
    base=https://github.com/ViRb3/wgcf/releases/download/${WGCF_VERSION}
    cd /tmp
    wget -q \$base/\$bin \$base/checksums.txt
    grep \" \$bin\\\$\" checksums.txt | sha256sum -c -
    chmod +x \$bin && cd /work
    /tmp/\$bin ${wgcf_cmd}
    /tmp/\$bin generate"

chmod 600 config/wgcf-account.toml config/wgcf-profile.conf
profile=config/wgcf-profile.conf
get() { awk -F' = ' -v k="$1" '$1==k {print $2; exit}' "$profile"; }

private_key=$(get PrivateKey)
public_key=$(get PublicKey)
# Keep only the IPv4 address; IPv6 is not routed (and is dropped by gluetun's firewall).
address_v4=$(get Address | tr ',' '\n' | tr -d ' ' | grep -E '^[0-9.]+/[0-9]+$' | head -1)

[[ -n "$private_key" && -n "$public_key" && -n "$address_v4" ]] || { echo "could not parse $profile" >&2; exit 1; }

umask 077
cat > config/warp.env <<EOF
WIREGUARD_PRIVATE_KEY=${private_key}
WIREGUARD_PUBLIC_KEY=${public_key}
WIREGUARD_ADDRESSES=${address_v4}
WIREGUARD_ENDPOINT_IP=${WARP_ENDPOINT_IP}
WIREGUARD_ENDPOINT_PORT=${WARP_ENDPOINT_PORT}
EOF
echo "✓ wrote config/warp.env (address ${address_v4}, endpoint ${WARP_ENDPOINT_IP}:${WARP_ENDPOINT_PORT})"
