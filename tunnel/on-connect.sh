#!/bin/sh
# Called by usque after each successful (re)connect: send all traffic into the tunnel.
set -eu
. /usr/local/lib/warp-tunnel/lib.sh
warp_default_route
log "connected; default route → $WARP_IF"
