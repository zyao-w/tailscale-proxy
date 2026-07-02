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
# Bridge tailnet targets to local ports via tailscaled's SOCKS5 proxy.
#
# Because tailscaled runs in userspace-networking mode, other processes
# (nginx / NPM) cannot reach 100.x.x.x directly. socat listens on a local
# port and forwards each connection through SOCKS5 to the tailnet target.
#
# Configure via env var TS_FORWARDS, semicolon-separated:
#   TS_FORWARDS="18581:100.64.1.5:8581;15000:100.64.1.5:5000"
#
# Then in NPM use 127.0.0.1:<local-port> as the Forward Hostname/Port.
# ---------------------------------------------------------------------------
if [ -n "${TS_FORWARDS}" ]; then
  IFS=';' read -ra RULES <<< "${TS_FORWARDS}"
  for rule in "${RULES[@]}"; do
    rule="$(echo "$rule" | xargs)"   # trim
    [ -z "$rule" ] && continue
    local_port="${rule%%:*}"
    rest="${rule#*:}"
    remote_host="${rest%%:*}"
    remote_port="${rest##*:}"
    echo "[start] socat bridge 127.0.0.1:${local_port} -> ${remote_host}:${remote_port} (via SOCKS5)"
    socat TCP-LISTEN:${local_port},fork,reuseaddr,bind=127.0.0.1 \
          SOCKS4A:localhost:${remote_host}:${remote_port},socksport=${TS_SOCKS_PORT} &
  done
fi

trap "kill -TERM ${TS_PID} 2>/dev/null || true" TERM INT

echo "[start] handing over to NPM (/init)"
exec /init
