#!/bin/sh
# Healthy only if traffic from this namespace provably exits via WARP.
curl -s --max-time 6 https://www.cloudflare.com/cdn-cgi/trace | grep -Eq '^warp=(on|plus)$'
