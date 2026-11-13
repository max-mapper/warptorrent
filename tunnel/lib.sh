#!/bin/sh
# warp-tunnel library: sourced by entrypoint.sh, on-connect.sh and healthcheck.sh, and usable
# from an extending image's hooks file. Sourcing it has no side effects.
#
# Settings (environment):
#   WARP_MODE         masque (HTTP/3 via usque) | wireguard              default: masque
#   WARP_IF           tunnel interface name                               default: warp0
#   WARP_IPV6         1 = also carry IPv6 through the tunnel; 0 = drop it default: 0
#   WARP_CONFIG_DIR   holds usque.json / wgcf-profile.conf                default: /config
#   WARP_WG_ENDPOINT  WireGuard endpoint, literal IPv4:port               default: 162.159.192.1:2408
#   WARP_DNS          resolvers, reachable only through the tunnel        default: Cloudflare's
#   BRIDGE_TCP_PORTS  TCP ports accepted from the Docker bridge subnet only (e.g. a web UI that
#                     the tunnel container publishes to the host)       default: none
#   WARP_HOOKS        hooks file sourced by entrypoint.sh                 default: /etc/warp-tunnel/hooks.sh
#
# Hooks: an extending image can define these shell functions in $WARP_HOOKS. Each is optional
# and runs inside the entrypoint, where UPLINK, GW, BRIDGE, ENDPOINT and EP_PORT are set.
#   hook_firewall  set NFT_INPUT / NFT_FORWARD / NFT_OUTPUT (rules spliced into those chains,
#                  before their final drop) and NFT_EXTRA (extra counters/chains in the table)
#   hook_routes    add routes / policy rules; runs after the base routes, before the tunnel
#   hook_start     start extra processes after the tunnel is up; add their PIDs to WATCH_PIDS
#                  so the container exits (and its restart policy applies) if one dies
#   hook_health    extra healthcheck; non-zero exit = unhealthy
#   hook_stop      runs on SIGTERM before watched processes are signalled

export WARP_MODE="${WARP_MODE:-masque}"
export WARP_IF="${WARP_IF:-warp0}"
export WARP_IPV6="${WARP_IPV6:-0}"
export WARP_CONFIG_DIR="${WARP_CONFIG_DIR:-/config}"
export WARP_WG_ENDPOINT="${WARP_WG_ENDPOINT:-162.159.192.1:2408}"
if [ "$WARP_IPV6" = 1 ]; then
  export WARP_DNS="${WARP_DNS:-1.1.1.1 1.0.0.1 2606:4700:4700::1111 2606:4700:4700::1001}"
else
  export WARP_DNS="${WARP_DNS:-1.1.1.1 1.0.0.1}"
fi
BRIDGE_TCP_PORTS="${BRIDGE_TCP_PORTS:-}"
WARP_HOOKS="${WARP_HOOKS:-/etc/warp-tunnel/hooks.sh}"
WARP_STATE=/run/warp-tunnel
WATCH_PIDS=""
NFT_INPUT="" NFT_FORWARD="" NFT_OUTPUT="" NFT_EXTRA=""

log() { echo "[tunnel] $*"; }
die() { echo "[tunnel] error: $*" >&2; exit 1; }
is_ipv4() { echo "$1" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; }
call_hook() { if command -v "$1" >/dev/null 2>&1; then "$1"; fi; }
warp_load_hooks() { if [ -f "$WARP_HOOKS" ]; then . "$WARP_HOOKS"; fi; }

# The Docker-side interface, its gateway and subnet. Read before the default route is removed.
warp_detect_uplink() {
  UPLINK=$(ip -4 route show default | awk '{for(i=1;i<NF;i++) if ($i=="dev") {print $(i+1); exit}}')
  GW=$(ip -4 route show default | awk '{for(i=1;i<NF;i++) if ($i=="via") {print $(i+1); exit}}')
  BRIDGE=$(ip -4 route show dev "${UPLINK:-none}" scope link 2>/dev/null | awk '{print $1; exit}')
  [ -n "$UPLINK" ] && [ -n "$GW" ] && [ -n "$BRIDGE" ] ||
    die "could not read the Docker network (uplink=$UPLINK gw=$GW bridge=$BRIDGE)"
}

# The single endpoint the tunnel itself may talk to.
warp_read_endpoint() {
  case "$WARP_MODE" in
    masque)
      CONFIG="$WARP_CONFIG_DIR/usque.json"
      [ -s "$CONFIG" ] || die "missing $CONFIG (run: register masque)"
      ENDPOINT=$(jq -r '.endpoint_v4 // empty' "$CONFIG")
      EP_PORT=443 ;;
    wireguard)
      CONFIG="$WARP_CONFIG_DIR/wgcf-profile.conf"
      [ -s "$CONFIG" ] || die "missing $CONFIG (run: register wireguard)"
      ENDPOINT="${WARP_WG_ENDPOINT%:*}"
      EP_PORT="${WARP_WG_ENDPOINT##*:}" ;;
    *) die "WARP_MODE must be masque or wireguard, not '$WARP_MODE'" ;;
  esac
  is_ipv4 "$ENDPOINT" || die "bad WARP endpoint '$ENDPOINT'"
}

# One nftables table, every hook default-drop, loaded atomically. Blocked packets are counted
# in named counters so a verifier can prove nothing slipped out.
warp_firewall() {
  call_hook hook_firewall
  v6=""
  [ "$WARP_IPV6" = 1 ] || v6='meta nfproto ipv6 counter name ipv6_blocked drop'
  bridge=""
  for p in $(echo "$BRIDGE_TCP_PORTS" | tr ',' ' '); do
    bridge="$bridge
    iifname \"$UPLINK\" ip saddr $BRIDGE tcp dport $p accept"
  done
  mkdir -p "$WARP_STATE"
  cat > "$WARP_STATE/ruleset.nft" <<EOF
table inet warp
delete table inet warp
table inet warp {
  counter in_blocked {}
  counter fwd_blocked {}
  counter out_blocked {}
  counter out_tunnel {}
  counter ipv6_blocked {}

  chain input {
    type filter hook input priority filter; policy drop;
    iif "lo" accept
    $v6
    ct state established,related accept
    ct state invalid drop$bridge
    $NFT_INPUT
    counter name in_blocked drop
  }

  chain forward {
    type filter hook forward priority filter; policy drop;
    $v6
    $NFT_FORWARD
    counter name fwd_blocked drop
  }

  chain output {
    type filter hook output priority filter; policy drop;
    oif "lo" accept
    $v6
    oifname "$WARP_IF" accept
    oifname "$UPLINK" ip daddr $ENDPOINT udp dport $EP_PORT counter name out_tunnel accept
    $NFT_OUTPUT
    counter name out_blocked drop
  }
$NFT_EXTRA
}
EOF
  nft -f "$WARP_STATE/ruleset.nft"
  log "firewall: default drop; out only via $WARP_IF and udp/$EP_PORT → $ENDPOINT${BRIDGE_TCP_PORTS:+; tcp/$BRIDGE_TCP_PORTS in from $BRIDGE}"
}

# Remove every default route. The only uplink route left is a /32 to the endpoint. An
# 'unreachable' default (high metric) makes lookups fail fast while the tunnel is down instead
# of falling through to later routing rules.
warp_routes() {
  ip route replace "$ENDPOINT/32" via "$GW" dev "$UPLINK"
  while ip -4 route del default 2>/dev/null; do :; done
  ip -4 route replace unreachable default metric 4000
  if [ "$WARP_IPV6" = 1 ]; then
    while ip -6 route del default 2>/dev/null; do :; done
    ip -6 route replace unreachable default metric 4000
  fi
  for d in $WARP_DNS; do echo "nameserver $d"; done > /etc/resolv.conf
  log "routing: no default route; $ENDPOINT/32 via $GW; DNS $WARP_DNS (tunnel only)"
}

warp_default_route() {
  ip -4 route replace default dev "$WARP_IF"
  if [ "$WARP_IPV6" = 1 ]; then ip -6 route replace default dev "$WARP_IF" 2>/dev/null || true; fi
}

wait_for_link() {
  i=0
  until ip link show "$1" >/dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -le 150 ] || die "$1 never appeared"
    if [ -n "${2:-}" ] && ! kill -0 "$2" 2>/dev/null; then die "tunnel process exited"; fi
    sleep 0.1
  done
}

warp_start_tunnel() {
  case "$WARP_MODE" in
    masque)
      flags="--always-reconnect --on-connect /usr/local/lib/warp-tunnel/on-connect.sh"
      [ "$WARP_IPV6" = 1 ] || flags="$flags --no-tunnel-ipv6"
      log "starting usque: MASQUE (HTTP/3) to $ENDPOINT:$EP_PORT"
      # shellcheck disable=SC2086
      usque nativetun -c "$CONFIG" -n "$WARP_IF" $flags &
      WATCH_PIDS="$WATCH_PIDS $!"
      # usque connects lazily, so route into the interface as soon as it exists;
      # on-connect.sh re-applies this after every reconnect.
      wait_for_link "$WARP_IF" "$!" ;;
    wireguard)
      # Values can end in '=' (base64), so strip the 'Key = ' prefix rather than split on '='.
      prof() { awk -v k="$1" 'match($0, "^" k " *= *") {print substr($0, RLENGTH + 1)}' "$CONFIG" | tr ',' '\n' | tr -d ' \r'; }
      priv=$(prof PrivateKey); pub=$(prof PublicKey); addrs=$(prof Address)
      [ -n "$priv" ] && [ -n "$pub" ] && [ -n "$addrs" ] || die "could not parse $CONFIG"
      if ip link add "$WARP_IF" type wireguard 2>/dev/null; then
        log "starting WireGuard (kernel) to $ENDPOINT:$EP_PORT"
      else
        log "starting WireGuard (wireguard-go, no kernel module) to $ENDPOINT:$EP_PORT"
        WG_I_PREFER_BUGGY_USERSPACE_TO_POLISHED_KMOD=1 WG_PROCESS_FOREGROUND=1 wireguard-go "$WARP_IF" &
        WATCH_PIDS="$WATCH_PIDS $!"
        wait_for_link "$WARP_IF" "$!"
      fi
      allowed=0.0.0.0/0
      if [ "$WARP_IPV6" = 1 ]; then allowed="$allowed,::/0"; fi
      (umask 077; echo "$priv" > "$WARP_STATE/wg.key")
      # wg prints the key on a parse error, so keep its stderr out of the logs.
      wg set "$WARP_IF" private-key "$WARP_STATE/wg.key" \
        peer "$pub" endpoint "$ENDPOINT:$EP_PORT" allowed-ips "$allowed" persistent-keepalive 25 \
        2>/dev/null || { rm -f "$WARP_STATE/wg.key"; die "wg set failed: bad key in $CONFIG?"; }
      rm -f "$WARP_STATE/wg.key"
      for a in $addrs; do
        case "$a" in
          *:*) if [ "$WARP_IPV6" = 1 ]; then ip -6 addr add "$a" dev "$WARP_IF"; fi ;;
          *) ip -4 addr add "$a" dev "$WARP_IF" ;;
        esac
      done
      ip link set "$WARP_IF" mtu 1280 up ;;
  esac
  warp_default_route
  log "default route → $WARP_IF"
  cat > "$WARP_STATE/state" <<EOF
MODE=$WARP_MODE
WARP_IF=$WARP_IF
WARP_IPV6=$WARP_IPV6
ENDPOINT=$ENDPOINT
EP_PORT=$EP_PORT
UPLINK=$UPLINK
GW=$GW
BRIDGE=$BRIDGE
EOF
}

warp_stop() {
  trap - TERM INT
  call_hook hook_stop || true
  for p in $WATCH_PIDS; do kill -TERM "$p" 2>/dev/null || true; done
  for p in $WATCH_PIDS; do wait "$p" 2>/dev/null || true; done
  exit "$1"
}

# Exit as soon as any watched process dies (or a kernel WireGuard link disappears), so the
# container's restart policy, not a half-working namespace, decides what happens next.
warp_supervise() {
  trap 'warp_stop 0' TERM INT
  while true; do
    sleep 5 & wait $! || true
    for p in $WATCH_PIDS; do
      kill -0 "$p" 2>/dev/null || { log "process $p exited; stopping"; warp_stop 1; }
    done
    ip link show "$WARP_IF" >/dev/null 2>&1 || { log "$WARP_IF disappeared; stopping"; warp_stop 1; }
  done
}

# Healthy only if traffic from this namespace provably exits via WARP.
warp_trace_ok() {
  curl -s --max-time 6 https://www.cloudflare.com/cdn-cgi/trace | grep -Eq '^warp=(on|plus)$'
}

# Registers an anonymous free WARP device (accepts Cloudflare's WARP ToS). No login needed.
warp_register() {
  mode="${1:-$WARP_MODE}"
  mkdir -p "$WARP_CONFIG_DIR" && cd "$WARP_CONFIG_DIR"
  case "$mode" in
    masque)
      if [ -s usque.json ]; then log "reusing usque.json"; return; fi
      usque register --accept-tos -c usque.json
      chmod 600 usque.json ;;
    wireguard)
      if [ -s wgcf-profile.conf ]; then log "reusing wgcf-profile.conf"; return; fi
      [ -s wgcf-account.toml ] || wgcf register --accept-tos
      wgcf generate
      chmod 600 wgcf-account.toml wgcf-profile.conf ;;
    *) die "register: mode must be masque or wireguard" ;;
  esac
  log "registered a WARP device for $mode in $WARP_CONFIG_DIR"
}
