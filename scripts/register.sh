#!/usr/bin/env bash
# Usage: scripts/register.sh <tunnel-image> <masque|wireguard> <config-dir>
# Registers an anonymous free Cloudflare WARP device (accepts Cloudflare's WARP ToS) using the
# tools inside the tunnel image, so nothing gets installed on the host, and writes the keys to
# <config-dir> (usque.json for MASQUE, wgcf-account.toml + wgcf-profile.conf for WireGuard).
# No Cloudflare login or API token is needed. Existing keys are reused.
set -euo pipefail
image="$1" mode="$2" dir="$3"
mkdir -p "$dir"; chmod 700 "$dir"
dir="$(cd "$dir" && pwd)"
echo "→ registering a WARP device for $mode (accepts Cloudflare's WARP ToS)…"
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$dir:/config" "$image" register "$mode"
