#!/usr/bin/env bash
# Registers an anonymous free Cloudflare WARP device for MASQUE mode with usque (run inside
# the tunnel image, so nothing gets installed on the host) and saves config/usque.json.
# No Cloudflare login or API token is needed.
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p config
chmod 700 config

if [[ -s config/usque.json ]]; then
  echo "→ reusing existing config/usque.json"
  exit 0
fi

echo "→ building MASQUE tunnel image"
docker build -q -t warptorrent-masque tunnel-masque >/dev/null

echo "→ registering a new WARP device for MASQUE (accepts Cloudflare's WARP ToS)…"
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "$PWD/config:/config" -w /config --entrypoint usque \
  warptorrent-masque register --accept-tos -c /config/usque.json

chmod 600 config/usque.json
echo "✓ wrote config/usque.json"
