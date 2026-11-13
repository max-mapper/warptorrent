#!/bin/sh
# Healthy only if traffic from this namespace provably exits via WARP (and, in an extending
# image, its hook_health passes).
. /usr/local/lib/warp-tunnel/lib.sh
warp_resolv_ok || exit 1
warp_trace_ok || exit 1
warp_load_hooks
call_hook hook_health
