#!/usr/bin/env bash
# Usage: scripts/leaktest.sh [tunnel-container]        (default: warptorrent-tunnel)
#
# Proves the kill switch of a running warp-tunnel container (either mode):
#   1. Egress inside the namespace is a WARP IP, different from the host's real IPs.
#   2. Simulated WARP outage (packets to the WARP endpoint are dropped, so the tunnel is dead
#      but still "up"): nothing gets out, by IP or by hostname, over TCP, UDP or ICMP.
#   3. Tunnel interface down: same, nothing gets out.
# Each probe re-checks that the fault is still in place, because the tunnel actively tries to
# heal itself, and a probe through a healed tunnel would prove nothing.
# Probes run in throwaway containers that join the tunnel's namespace, the way a client
# container does. They have no capabilities, so they can't set socket marks or touch the firewall.
# Leaves the tunnel restarted and healthy.
set -euo pipefail

C="${1:-warptorrent-tunnel}"
NS="container:$C"
state() { docker exec "$C" sh -c ". /run/warp-tunnel/state; echo \$$1"; }
MODE=$(state MODE); ENDPOINT=$(state ENDPOINT); WARP_IF=$(state WARP_IF)
echo "tunnel $C: mode $MODE, interface $WARP_IF, endpoint $ENDPOINT"
pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*"; exit 1; }
trace() { docker run --rm --network "$NS" curlimages/curl:latest -s --max-time "${1:-15}" https://www.cloudflare.com/cdn-cgi/trace; }

wait_healthy() {
  local i=0
  until [[ "$(docker inspect -f '{{.State.Health.Status}}' "$C")" == healthy ]]; do
    i=$((i + 1)); ((i < 60)) || fail "tunnel did not become healthy again"; sleep 2
  done
}
restore() { echo "→ restoring: restarting tunnel"; docker restart "$C" >/dev/null; wait_healthy; }
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

# probes <fault-check-cmd>: every probe must fail while the fault check still holds
probes() {
  local still_faulted="$1"
  run() { # name, cmd...
    local name="$1"; shift
    eval "$still_faulted" || fail "fault healed before probe '$name', inconclusive"
    if "$@" >/dev/null 2>&1; then
      eval "$still_faulted" || fail "fault healed during probe '$name', inconclusive"
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

echo "2) simulated WARP outage (drop all packets to/from $ENDPOINT)"
docker exec "$C" nft insert rule inet warp output ip daddr "$ENDPOINT" drop comment '"leaktest"'
docker exec "$C" nft insert rule inet warp input ip saddr "$ENDPOINT" drop comment '"leaktest"'
sleep 3
probes "docker exec $C nft list chain inet warp output | grep leaktest >/dev/null"
restore

echo "3) tunnel interface down"
docker exec "$C" ip link set "$WARP_IF" down
probes "! docker exec $C ip link show $WARP_IF 2>/dev/null | grep -q ',UP'"

echo "all leak checks passed"
