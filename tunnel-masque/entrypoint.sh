#!/bin/sh
# Kill switch first, tunnel second. Everything below runs before usque starts, and any
# failure exits the container (set -e) rather than leaving a half-configured namespace.
#
# After this script:
#   - iptables: INPUT/OUTPUT/FORWARD policy DROP. Allowed: loopback, replies to allowed
#     flows, anything out tun0, UDP 443 to the one MASQUE endpoint, and the stream port
#     inbound from the Docker bridge subnet only.
#   - ip6tables: everything dropped (IPv6 is also disabled by sysctl).
#   - routing: the normal default route is DELETED. Only a /32 to the MASQUE endpoint goes
#     via the Docker gateway. Default via tun0 is added by on-connect.sh. Without the tunnel
#     there is no route to the internet at all, independent of the firewall.
#   - DNS: 1.1.1.1 / 1.0.0.1, reachable only through tun0 (Docker's embedded resolver is
#     bypassed because it forwards queries from the host, outside the tunnel).
set -eu

CONFIG=/config/usque.json
STREAM_PORT="${STREAM_PORT:-8888}"

[ -s "$CONFIG" ] || { echo "[tunnel] missing $CONFIG — run scripts/setup-masque.sh" >&2; exit 1; }
ENDPOINT=$(jq -r '.endpoint_v4 // empty' "$CONFIG")
echo "$ENDPOINT" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || { echo "[tunnel] bad endpoint_v4: '$ENDPOINT'" >&2; exit 1; }

IFACE=$(ip -4 route show default | awk '{for(i=1;i<NF;i++) if ($i=="dev") {print $(i+1); exit}}')
GW=$(ip -4 route show default | awk '{for(i=1;i<NF;i++) if ($i=="via") {print $(i+1); exit}}')
BRIDGE=$(ip -4 route show dev "$IFACE" scope link | awk '{print $1; exit}')
[ -n "$IFACE" ] && [ -n "$GW" ] && [ -n "$BRIDGE" ] || { echo "[tunnel] could not read Docker network (iface=$IFACE gw=$GW bridge=$BRIDGE)" >&2; exit 1; }

echo "[tunnel] firewall: default drop; allow tun0, udp/443 → $ENDPOINT via $IFACE, tcp/$STREAM_PORT from $BRIDGE"
iptables -P INPUT DROP
iptables -P OUTPUT DROP
iptables -P FORWARD DROP
iptables -F
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -o "$IFACE" -d "$ENDPOINT" -p udp --dport 443 -j ACCEPT
iptables -A OUTPUT -o tun0 -j ACCEPT
iptables -A INPUT  -i "$IFACE" -s "$BRIDGE" -p tcp --dport "$STREAM_PORT" -j ACCEPT

ip6tables -P INPUT DROP
ip6tables -P OUTPUT DROP
ip6tables -P FORWARD DROP
ip6tables -F

echo "[tunnel] routing: remove default route; $ENDPOINT/32 via $GW"
ip route replace "$ENDPOINT/32" via "$GW" dev "$IFACE"
ip route del default

printf 'nameserver 1.1.1.1\nnameserver 1.0.0.1\n' > /etc/resolv.conf

echo "[tunnel] starting usque (MASQUE over HTTP/3 to $ENDPOINT:443)"
usque nativetun -c "$CONFIG" -n tun0 --no-tunnel-ipv6 --always-reconnect --on-connect /on-connect.sh &
pid=$!
trap 'kill -TERM "$pid" 2>/dev/null' TERM INT

# usque connects lazily on outbound traffic, so point the default route at tun0 as soon as the
# interface exists (on-connect.sh re-applies it after every reconnect).
i=0
until ip link show tun0 >/dev/null 2>&1; do
  i=$((i + 1)); [ "$i" -le 100 ] || { echo "[tunnel] tun0 never appeared" >&2; kill "$pid"; exit 1; }
  kill -0 "$pid" 2>/dev/null || { echo "[tunnel] usque exited" >&2; exit 1; }
  sleep 0.1
done
ip route replace default dev tun0
echo "[tunnel] default route → tun0"

wait "$pid"
