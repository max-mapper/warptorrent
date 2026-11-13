#!/bin/sh
# warp-tunnel entrypoint. Kill switch first, tunnel second: the firewall and routes are in
# place before any tunnel or hook process starts, and any setup failure exits the container
# (set -e) rather than leaving a half-configured namespace.
#
#   (no args) | run        bring up the tunnel and supervise it
#   register [MODE]        register an anonymous WARP device into $WARP_CONFIG_DIR, then exit
#   <anything else>        exec it (debugging)
set -eu
. /usr/local/lib/warp-tunnel/lib.sh

case "${1:-run}" in
  run) ;;
  register) shift; warp_register "$@"; exit 0 ;;
  *) exec "$@" ;;
esac

warp_load_hooks
warp_detect_uplink
warp_read_endpoint
warp_firewall
warp_routes
call_hook hook_routes
warp_start_tunnel
call_hook hook_start
warp_supervise
