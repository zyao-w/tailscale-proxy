#!/bin/bash
set -e

: "${TS_AUTHKEY:?TS_AUTHKEY is required}"
: "${TS_HOSTNAME:=zeabur-npm}"
: "${TS_STATE_DIR:=/var/lib/tailscale}"
: "${TS_ACCEPT_DNS:=false}"

mkdir -p "${TS_STATE_DIR}"

echo "[start] launching tailscaled (userspace)"
/usr/sbin/tailscaled \
  --tun=userspace-networking \
  --socks5-server=localhost:1055 \
  --outbound-http-proxy-listen=localhost:1055 \
  --state="${TS_STATE_DIR}/tailscaled.state" \
  --socket=/tmp/tailscaled.sock &
TS_PID=$!

# wait for socket
for i in $(seq 1 20); do
  [ -S /tmp/tailscaled.sock ] && break
  sleep 0.5
done

echo "[start] tailscale up as ${TS_HOSTNAME}"
/usr/bin/tailscale --socket=/tmp/tailscaled.sock up \
  --authkey="${TS_AUTHKEY}" \
  --hostname="${TS_HOSTNAME}" \
  --accept-dns="${TS_ACCEPT_DNS}" \
  --reset

/usr/bin/tailscale --socket=/tmp/tailscaled.sock status || true

# forward signals so tailscaled gets cleaned up
trap "kill -TERM ${TS_PID} 2>/dev/null || true" TERM INT

echo "[start] handing over to NPM (/init)"
exec /init
