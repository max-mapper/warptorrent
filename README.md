# warptorrent

Run WebTorrent so peers in the swarm only ever see a Cloudflare WARP IP, never yours.
If the WARP tunnel drops, the client has no network path at all.

```
./warptorrent "magnet:?xt=urn:btih:…" ~/Movies/torrents   # download into a folder
./warptorrent status                                       # show tunnel exit IP
./warptorrent leaktest                                     # prove the kill switch works
./warptorrent stop                                         # stop the tunnel container
```

The first run registers an anonymous free WARP device. No Cloudflare account, login, or API
token is needed. Output folder defaults to `./downloads`. If Docker runs inside a VM (Docker
Desktop, Colima, OrbStack), the folder must be somewhere that VM shares, which by default is your
home folder.

Requirements: Docker with `docker compose` (or `docker-compose`) and a bash shell. Any Docker that
runs Linux containers works: Docker Engine, Docker Desktop, Colima, OrbStack, or WSL2 on Windows.
Images are multi-arch (amd64 and arm64).

## How it works

```
 host ── Docker ──┬─ gluetun container ── tun0 ══ WireGuard ══> Cloudflare WARP (162.159.192.1:2408)
                  │   iptables: OUTPUT DROP except tun0 + UDP to the WARP endpoint
                  └─ torrent container (network_mode: service:gluetun, no network of its own)
                       └─ /downloads  ← bind mount of your output folder
```

- **WARP access:** `scripts/setup-warp.sh` runs [wgcf](https://github.com/ViRb3/wgcf) in a
  throwaway container (checksum-verified release binary). It registers a device and writes the
  WireGuard keys to `config/warp.env`, which is `chmod 600` and git-ignored.
- **Tunnel + kill switch:** [gluetun](https://github.com/qdm12/gluetun) runs the WireGuard client.
  Its default-drop firewall is the kill switch, and it lives in the kernel, not in any app
  process. DNS goes to Cloudflare 1.1.1.1 over DNS-over-TLS, inside the tunnel.
- **Torrent client:** the container has no network interface of its own. It borrows gluetun's
  namespace, so if gluetun stops the client is fully offline. It runs read-only, with no Linux
  capabilities, as your UID.
- **WebTorrent hardening** (`torrent/run.mjs`):
  - Router port mapping (UPnP / NAT-PMP) and local-network discovery (LSD) are off.
  - WebRTC is removed from the image: `webrtc-polyfill` is replaced by a stub in `torrent/no-webrtc/`.
    Its ICE candidates would otherwise announce local IPs.
  - The client refuses to start unless Cloudflare's trace page reports `warp=on`, re-checks
    every 30 s, and shuts down after 2 failed checks.

## Verified (2026-10-07, Docker via Colima on arm64)

`./warptorrent leaktest`:
- Exit IP is a WARP IP (`104.28.x.x`, `warp=on`). It differs from the host's real IPv4 and IPv6.
- **Simulated WARP outage** (all packets to the endpoint dropped): HTTPS by hostname, HTTPS to
  1.1.1.1, UDP DNS to 8.8.8.8 / 1.1.1.1 and ICMP were all blocked.
- **Tunnel interface down:** the same probes were all blocked.

Live test: Big Buck Bunny (276 MB) downloaded in about 30 s at about 14 MB/s from 10–16 peers.
Files were owned by the host user.

## Caveats

- **WARP is a privacy relay, not an anonymity network.** Swarm peers see a Cloudflare IP, but
  Cloudflare sees your real IP. WARP exit IPs also geolocate near you.
- **No port forwarding.** Peers can't connect to you, so you get fewer peers and weak seeding.
- **IPv4 only.** IPv6 is not routed through the tunnel, and gluetun's firewall drops it.
- **uTP is disabled.** `utp-native` has no prebuilt binary for this image (Linux/musl/arm64, Node 24),
  so it's replaced by a stub in `torrent/no-utp/` and WebTorrent uses TCP. The cost is small: uTP mainly
  helps reach uTP-only peers, and through WARP nobody can connect in to you anyway.
- **Tunnel drops are not retried by the client.** If gluetun is recreated while a download is
  running, the torrent container stays offline until you rerun the command. That's intended
  (fail closed).
- **`config/` holds secrets.** It contains your WARP private key. Don't share it.

## Future work: WARP over MASQUE

Today the tunnel is WireGuard on UDP `162.159.192.1:2408`. Your ISP can't see inside it, but the
WireGuard handshake is easy to fingerprint and the endpoint is a known WARP address. That makes
"this person uses a VPN" obvious, and volume/timing analysis could guess at BitTorrent.

WARP also supports **MASQUE**: IP packets carried over HTTP/3 (QUIC on UDP 443, RFC 9484
Connect-IP). On the wire that looks like ordinary HTTP/3 traffic to Cloudflare, which a huge share
of normal browsing also produces. That makes the tunnel much harder to single out.

Possible approach:
- Swap the gluetun WireGuard leg for [usque](https://github.com/Diniboy1123/usque), an open-source
  WARP MASQUE client. It has a native TUN mode and handles its own device registration.
- gluetun doesn't speak MASQUE, so the kill switch would move into our own container: an
  iptables default-drop policy allowing only the TUN interface and UDP/TCP 443 to the MASQUE
  endpoint, plus a healthcheck so the torrent container keeps `depends_on: service_healthy`.
- Re-run `leaktest.sh` (adapted for the new endpoint and interface names) to prove fail-closed
  behaviour before trusting it.

Caveats: usque describes itself as unstable, and this only changes what the tunnel looks like.
Total data volume and timing stay visible to the ISP either way.
