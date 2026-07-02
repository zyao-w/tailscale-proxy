#!/bin/bash
set -e

: "${TS_AUTHKEY:?TS_AUTHKEY is required}"
: "${TS_HOSTNAME:=zeabur-npm}"
: "${TS_STATE_DIR:=/var/lib/tailscale}"
: "${TS_ACCEPT_DNS:=false}"
: "${TS_SOCKS_PORT:=1055}"

mkdir -p "${TS_STATE_DIR}"

echo "[start] launching tailscaled (userspace)"
/usr/sbin/tailscaled \
  --tun=userspace-networking \
  --socks5-server=localhost:${TS_SOCKS_PORT} \
  --outbound-http-proxy-listen=localhost:${TS_SOCKS_PORT} \
  --state="${TS_STATE_DIR}/tailscaled.state" \
  --socket=/tmp/tailscaled.sock &
TS_PID=$!

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

# ---------------------------------------------------------------------------
# Manual bootstrap forwards via TS_FORWARDS (optional, for testing/fallback)
#   TS_FORWARDS="18581:100.64.1.5:8581;15000:100.64.1.5:5000"
# ---------------------------------------------------------------------------
if [ -n "${TS_FORWARDS:-}" ]; then
  IFS=';' read -ra RULES <<< "${TS_FORWARDS}"
  for rule in "${RULES[@]}"; do
    rule="$(echo "$rule" | xargs)"
    [ -z "$rule" ] && continue
    lp="${rule%%:*}"
    rest="${rule#*:}"
    rh="${rest%:*}"
    rp="${rest##*:}"
    echo "[start] manual socat 127.0.0.1:${lp} -> ${rh}:${rp} (via HTTP CONNECT)"
    socat TCP-LISTEN:${lp},fork,reuseaddr,bind=127.0.0.1 \
          PROXY:localhost:${rh}:${rp},proxyport=${TS_SOCKS_PORT} \
          >/dev/null 2>&1 &
  done
fi

echo "[start] launching autoforward watcher"
/usr/local/bin/autoforward.sh &

trap "kill -TERM ${TS_PID} 2>/dev/null || true" TERM INT

echo "[start] handing over to NPM (/init)"
exec /init
