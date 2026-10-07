#!/usr/bin/env bash
# Proves the kill switch works.
#   1. Egress inside the namespace is a WARP IP, different from the host's real IPs.
#   2. Simulated WARP outage (packets to the WARP endpoint are dropped, so the tunnel is
#      dead but still "up"): nothing gets out — by IP, by hostname, TCP or UDP.
#   3. Tunnel interface torn down: same, nothing gets out.
# Each probe re-checks that the fault is still in place, because gluetun's watchdog actively
# tries to heal the tunnel and a probe through a healed tunnel would prove nothing.
# Probes run in throwaway containers that join gluetun's namespace, like the torrent client.
set -euo pipefail
cd "$(dirname "$0")/.."

C=warptorrent-gluetun
NS="container:$C"
ENDPOINT=$(awk -F= '$1=="WIREGUARD_ENDPOINT_IP"{print $2}' config/warp.env)
pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*"; exit 1; }
trace() { docker run --rm --network "$NS" curlimages/curl:latest -s --max-time "${1:-15}" https://www.cloudflare.com/cdn-cgi/trace; }

restore() { echo "→ restoring: restarting gluetun"; docker restart "$C" >/dev/null; }
trap restore EXIT

docker pull -q curlimages/curl:latest >/dev/null; docker pull -q busybox:latest >/dev/null

echo "1) egress check"
real4=$(curl -4 -s --max-time 10 https://www.cloudflare.com/cdn-cgi/trace | awk -F= '$1=="ip"{print $2}' || true)
real6=$(curl -6 -s --max-time 10 https://www.cloudflare.com/cdn-cgi/trace | awk -F= '$1=="ip"{print $2}' || true)
t=$(trace); tun_ip=$(awk -F= '$1=="ip"{print $2}' <<<"$t"); warp=$(awk -F= '$1=="warp"{print $2}' <<<"$t")
echo "  host real IPv4: ${real4:-none}"
echo "  host real IPv6: ${real6:-none}"
echo "  tunnel IP     : $tun_ip (warp=$warp)"
[[ "$warp" == on || "$warp" == plus ]] || fail "namespace egress is not WARP"
[[ "$tun_ip" != "$real4" && "$tun_ip" != "$real6" ]] || fail "tunnel IP equals a real IP"
pass "namespace exits via WARP with a different IP"

# probe <fault-check-cmd> : all must fail while the fault check still holds
probes() {
  local still_faulted="$1"
  run() { # name, cmd...
    local name="$1"; shift
    eval "$still_faulted" || fail "fault healed before probe '$name' — inconclusive"
    if "$@" >/dev/null 2>&1; then
      eval "$still_faulted" || fail "fault healed during probe '$name' — inconclusive"
      fail "$name got through"
    fi
    pass "$name blocked"
  }
  run "HTTPS by hostname"   trace 8
  run "HTTPS to 1.1.1.1"    docker run --rm --network "$NS" curlimages/curl:latest -s --max-time 8 https://1.1.1.1/cdn-cgi/trace
  run "UDP DNS to 8.8.8.8"  docker run --rm --network "$NS" busybox:latest nslookup -timeout=5 example.com 8.8.8.8
  run "UDP DNS to 1.1.1.1"  docker run --rm --network "$NS" busybox:latest nslookup -timeout=5 example.com 1.1.1.1
  run "ICMP to 9.9.9.9"     docker run --rm --network "$NS" busybox:latest ping -c2 -W3 9.9.9.9
}

echo "2) simulated WARP outage (drop all packets to $ENDPOINT)"
docker exec "$C" iptables -I OUTPUT 1 -d "$ENDPOINT" -j DROP
docker exec "$C" iptables -I INPUT 1 -s "$ENDPOINT" -j DROP
sleep 3
probes "docker exec $C iptables -C OUTPUT -d $ENDPOINT -j DROP 2>/dev/null"
restore; docker exec "$C" true
until [[ "$(docker inspect -f '{{.State.Health.Status}}' "$C")" == healthy ]]; do sleep 2; done

echo "3) tunnel interface down"
docker exec "$C" ip link set tun0 down
probes "! docker exec $C ip link show tun0 2>/dev/null | grep -q ',UP'"

echo "all leak checks passed"
