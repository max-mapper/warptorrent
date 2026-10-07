# warptorrent

Run WebTorrent so peers in the swarm only ever see a Cloudflare WARP IP, never yours.
If the WARP tunnel drops, the client has no network path at all.

```
./warptorrent "magnet:?xt=urn:btih:…" ~/Movies/torrents            # download into a folder
./warptorrent --stream "magnet:?xt=urn:btih:…" ~/Movies/torrents   # …and stream it to VLC
./warptorrent --masque "magnet:?xt=urn:btih:…"                     # tunnel over MASQUE instead
./warptorrent status                                                # show tunnel exit IP
./warptorrent leaktest                                              # prove the kill switch works
```

The tunnel starts on demand and is torn down when the command exits, including on Ctrl-C or
`kill`. Nothing is left running in the background. If several downloads run at once, they share
one tunnel, and it stays up until the last one exits. While a download is running, starting
another in a different mode (or with a different `--port`) is refused, because recreating the
tunnel would cut the first one off.

| Option | Effect |
|---|---|
| `--masque` | Tunnel WARP over MASQUE (HTTP/3 on UDP 443) instead of WireGuard. See [Tunnel modes](#tunnel-modes). |
| `--stream` | Serve the torrent's files over HTTP on `127.0.0.1` and print a URL for each file as soon as the torrent's metadata arrives. The client keeps running after the download completes (streaming and seeding) until you press Ctrl-C, so playback isn't cut off. |
| `--port N` | Stream server port (default `8888`). |

Without `--stream`, the client exits as soon as the download completes.

Options apply to commands too: `./warptorrent --masque status` and `./warptorrent --masque leaktest`
test the MASQUE tunnel.

The first run in each mode registers an anonymous free WARP device. No Cloudflare account, login,
or API token is needed. Output folder defaults to `./downloads`. If Docker runs inside a VM
(Docker Desktop, Colima, OrbStack), the folder must be somewhere that VM shares, which by default
is your home folder.

Requirements: Docker with `docker compose` (or `docker-compose`) and a bash shell. Any Docker that
runs Linux containers works: Docker Engine, Docker Desktop, Colima, OrbStack, or WSL2 on Windows.
Images are multi-arch (amd64 and arm64).

## Streaming

With `--stream`, the output looks like:

```
[stream] open in VLC (Media → Open Network Stream) or any player:
[stream] ▶ http://127.0.0.1:8888/webtorrent/<infohash>/Big%20Buck%20Bunny/Big%20Buck%20Bunny.mp4
[stream]   http://127.0.0.1:8888/webtorrent/<infohash>/Big%20Buck%20Bunny/poster.jpg  (poster.jpg, 0.3 MB)
```

The largest file (usually the video) is marked `▶`. Paste its URL into VLC. Seeking works:
WebTorrent fetches the pieces you jump to first.

How the URL crosses the container boundary safely:
- WebTorrent's HTTP server listens inside the shared tunnel namespace. The tunnel container
  publishes that one port to the host on **`127.0.0.1` only**, so nothing on your LAN or the
  internet can reach it.
- The tunnel firewall accepts the stream port only from the Docker bridge subnet, never from the
  tunnel side.
- The server rejects any request whose `Host` header isn't `127.0.0.1:<port>`, which blocks
  DNS-rebinding attacks from web pages.
- CORS is limited to the server's own origin, so other websites open in your browser can't read
  the stream or the torrent list. Media players don't send an `Origin` header, so they're
  unaffected.

## Tunnel modes

| | WireGuard (default) | MASQUE (`--masque`) |
|---|---|---|
| On the wire | WireGuard, UDP `162.159.192.1:2408` | HTTP/3 (QUIC), UDP `162.159.198.x:443` |
| Looks like | an obvious VPN (WireGuard is easy to fingerprint) | ordinary HTTP/3 traffic to Cloudflare |
| Client | [gluetun](https://github.com/qdm12/gluetun) (mature, widely used) | [usque](https://github.com/Diniboy1123/usque) (open-source; describes itself as unstable) |
| Kill switch | gluetun's built-in firewall | our own entrypoint (`tunnel-masque/entrypoint.sh`) |
| WARP config | `config/warp.env` via [wgcf](https://github.com/ViRb3/wgcf) | `config/usque.json` via `usque register` |

Use MASQUE if you'd rather your ISP not see VPN traffic. Either way your ISP can't see what you're
downloading, but it can still see how much data you move and when.

## How it works

```
 host ── Docker ──┬─ tunnel container ── tun0 ══ WireGuard or MASQUE ══> Cloudflare WARP
                  │   firewall: default DROP; allow tun0, the one WARP endpoint,
                  │             and the stream port from the Docker bridge
                  │   publishes 127.0.0.1:8888 → stream server (host only)
                  └─ torrent container (network_mode: service:tunnel, no network of its own)
                       └─ /downloads  ← bind mount of your output folder
```

- **Compose layout:** `compose.yaml` defines the torrent client. Exactly one of
  `compose.wireguard.yaml` or `compose.masque.yaml` supplies the `tunnel` service; the wrapper
  picks it based on `--masque`.
- **WireGuard tunnel:** `scripts/setup-warp.sh` runs wgcf in a throwaway container
  (checksum-verified release binary) and writes the keys to `config/warp.env`. gluetun runs the
  tunnel. Its default-drop firewall lives in the kernel, not in any app process. DNS goes to
  Cloudflare 1.1.1.1 over DNS-over-TLS, inside the tunnel.
- **MASQUE tunnel:** `tunnel-masque/` builds a small Alpine image with a checksum-verified usque
  binary. `scripts/setup-masque.sh` registers a device into `config/usque.json`. Before usque
  starts, the entrypoint:
  1. sets iptables and ip6tables policies to DROP, allowing only loopback, replies, `tun0`,
     UDP 443 to the one MASQUE endpoint, and the stream port from the Docker bridge;
  2. **deletes the normal default route**, leaving only a /32 route to the endpoint. Without the
     tunnel there is no route to the internet, independent of the firewall;
  3. points DNS at 1.1.1.1 / 1.0.0.1, which are reachable only through `tun0`. Docker's built-in
     resolver is bypassed because it would forward queries from the host, outside the tunnel.

  Any setup failure exits the container rather than continuing half-configured. A healthcheck
  requires `warp=on` before the torrent client starts.
- **Torrent client:** the container has no network interface of its own. It borrows the tunnel's
  namespace, so if the tunnel container stops, the client is fully offline. It runs read-only,
  with no Linux capabilities, as your UID.
- **WebTorrent hardening** (`torrent/run.mjs`):
  - Router port mapping (UPnP / NAT-PMP) and local-network discovery (LSD) are off.
  - WebRTC is removed from the image: `webrtc-polyfill` is replaced by a stub in
    `torrent/no-webrtc/`. Its ICE candidates would otherwise announce local IPs.
  - The client refuses to start unless Cloudflare's trace page reports `warp=on`, re-checks
    every 30 s, and shuts down after 2 failed checks.

## Verified (2026-10-07, Docker via Colima on arm64)

`./warptorrent leaktest` and `./warptorrent --masque leaktest` both pass:
- Exit IP is a WARP IP (`104.28.x.x`, `warp=on`). It differs from the host's real IPv4 and IPv6.
- **Simulated WARP outage** (all packets to the endpoint dropped): HTTPS by hostname, HTTPS to
  1.1.1.1, UDP DNS to 8.8.8.8 / 1.1.1.1 and ICMP were all blocked.
- **Tunnel interface down:** the same probes were all blocked.

Live tests with Big Buck Bunny (276 MB) in both modes:
- Downloaded in about 30–35 s at roughly 10–16 MB/s. Files were owned by the host user.
- With `--stream`, range requests from the host returned `206 video/mp4` mid-download in both
  modes. In the MASQUE run they also kept working after the download completed.
- A forged `Host` header was rejected (WireGuard run). A foreign `Origin` got no CORS access
  (MASQUE run).

## Caveats

- **WARP is a privacy relay, not an anonymity network.** Swarm peers see a Cloudflare IP, but
  Cloudflare sees your real IP. WARP exit IPs also geolocate near you.
- **No port forwarding.** Peers can't connect to you, so you get fewer peers and weak seeding.
- **IPv4 only.** IPv6 is not routed through either tunnel, and both firewalls drop it.
- **uTP is disabled.** `utp-native` has no prebuilt binary for this image (Linux/musl/arm64,
  Node 24), so it's replaced by a stub in `torrent/no-utp/` and WebTorrent uses TCP. The cost is
  small: uTP mainly helps reach uTP-only peers, and through WARP nobody can connect in to you anyway.
- **Tunnel failures end the download.** If the tunnel container dies mid-download (for example
  usque crashes), the client stays offline, and its guard shuts it down within about a minute.
  Rerun the command to resume; WebTorrent picks up from the pieces already on disk. The tunnel
  never restarts on its own, including after a reboot, and is fail closed throughout.
- **MASQUE depends on usque.** usque describes itself as unstable. If it breaks, fall back to the
  default WireGuard mode.
- **`config/` holds secrets.** It contains your WARP private keys for both modes. Don't share it.
