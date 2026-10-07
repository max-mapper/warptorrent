#!/bin/sh
# Called by usque after each successful (re)connect: send all traffic into the tunnel.
set -eu
ip route replace default dev tun0
echo "[tunnel] connected; default route → tun0"
