#!/bin/bash
# ------------------------------------------------------------------------------
# autoforward.sh
#
# Watches NPM's generated nginx configs under /data/nginx/proxy_host/ and,
# for any upstream that points to a tailnet target (100.x.x.x or *.ts.net),
# automatically:
#   1. allocates a deterministic local port
#   2. starts a socat SOCKS5 bridge to the tailnet target
#   3. rewrites the .conf to use 127.0.0.1:<local-port>
#   4. reloads nginx
#
# Stale socat processes for targets no longer present are cleaned up.
# ------------------------------------------------------------------------------
set -u

CONF_DIR="/data/nginx/proxy_host"
STATE_DIR="/var/lib/tailscale"
STATE_FILE="${STATE_DIR}/autoforward.state"     # "host:port localport pid" per line
SOCKS_PORT="${TS_SOCKS_PORT:-1055}"
PORT_BASE=20000
PORT_RANGE=10000
POLL_INTERVAL=3

mkdir -p "${STATE_DIR}"
touch "${STATE_FILE}"

log() { echo "[autoforward] $*"; }

# Deterministic port from "host:port" so restarts reuse the same allocation.
alloc_port() {
  local key="$1"
  local hash
  hash=$(printf '%s' "${key}" | md5sum | awk '{print $1}')
  # Take last 8 hex chars → decimal → mod range
  local num=$((0x${hash: -8}))
  echo $(( PORT_BASE + (num % PORT_RANGE) ))
}

ensure_socat() {
  local key="$1"       # host:port
  local lport="$2"
  local host="${key%:*}"
  local rport="${key##*:}"

  # Already running?
  if grep -qE "^${key} ${lport} " "${STATE_FILE}" 2>/dev/null; then
    local pid
    pid=$(awk -v k="${key}" -v p="${lport}" '$1==k && $2==p {print $3}' "${STATE_FILE}")
    if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
      return 0
    fi
  fi

  log "start socat 127.0.0.1:${lport} -> ${host}:${rport} (via SOCKS5)"
  socat TCP-LISTEN:${lport},fork,reuseaddr,bind=127.0.0.1 \
        SOCKS4A:localhost:${host}:${rport},socksport=${SOCKS_PORT} \
        >/dev/null 2>&1 &
  local pid=$!
  # Replace any existing line for this key
  grep -v -E "^${key} " "${STATE_FILE}" > "${STATE_FILE}.tmp" || true
  echo "${key} ${lport} ${pid}" >> "${STATE_FILE}.tmp"
  mv "${STATE_FILE}.tmp" "${STATE_FILE}"
}

cleanup_stale() {
  local active_keys="$1"    # newline-separated list of host:port still in use
  local tmp="${STATE_FILE}.tmp"
  : > "${tmp}"
  while read -r line; do
    [ -z "${line}" ] && continue
    local key lport pid
    key=$(echo "${line}" | awk '{print $1}')
    lport=$(echo "${line}" | awk '{print $2}')
    pid=$(echo "${line}" | awk '{print $3}')
    if echo "${active_keys}" | grep -qx "${key}"; then
      echo "${line}" >> "${tmp}"
    else
      log "stop socat for ${key} (pid ${pid})"
      kill "${pid}" 2>/dev/null || true
    fi
  done < "${STATE_FILE}"
  mv "${tmp}" "${STATE_FILE}"
}

last_checksum=""

process_configs() {
  [ -d "${CONF_DIR}" ] || return 0

  # Snapshot to detect changes cheaply
  local checksum
  checksum=$(find "${CONF_DIR}" -type f -name '*.conf' -exec md5sum {} + 2>/dev/null | md5sum | awk '{print $1}')
  [ "${checksum}" = "${last_checksum}" ] && return 0
  last_checksum="${checksum}"

  log "config change detected, scanning ${CONF_DIR}"

  local active_keys=""
  local changed_any=0

  for conf in "${CONF_DIR}"/*.conf; do
    [ -f "${conf}" ] || continue

    # Extract tailnet targets. NPM's confs use `set $server "…";` and `set $port …;`
    # or a direct `proxy_pass http://host:port;`. Handle both.
    #
    # Pattern 1: set $server "100.x.x.x"; ... set $port 8581;
    local server port
    server=$(grep -oE 'set\s+\$server\s+"[^"]+"' "${conf}" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
    port=$(grep -oE 'set\s+\$port\s+[0-9]+' "${conf}" | head -1 | awk '{print $NF}')

    if [ -n "${server}" ] && [ -n "${port}" ]; then
      if echo "${server}" | grep -qE '^100\.|\.ts\.net$'; then
        local key="${server}:${port}"
        local lport
        lport=$(alloc_port "${key}")
        ensure_socat "${key}" "${lport}"
        active_keys="${active_keys}${key}"$'\n'

        # Rewrite conf: point $server/$port to loopback
        if ! grep -qE "set\s+\$server\s+\"127\.0\.0\.1\"" "${conf}" \
           || ! grep -qE "set\s+\$port\s+${lport}\b" "${conf}"; then
          sed -i -E "s#(set\s+\\\$server\s+)\"[^\"]+\"#\\1\"127.0.0.1\"#" "${conf}"
          sed -i -E "s#(set\s+\\\$port\s+)[0-9]+#\\1${lport}#" "${conf}"
          # Preserve original target as a comment marker for humans
          if ! grep -q "# tailnet-target: ${key}" "${conf}"; then
            sed -i "1i # tailnet-target: ${key} -> 127.0.0.1:${lport}" "${conf}"
          else
            sed -i -E "s|^# tailnet-target: .*|# tailnet-target: ${key} -> 127.0.0.1:${lport}|" "${conf}"
          fi
          changed_any=1
          log "rewrote ${conf##*/} → 127.0.0.1:${lport} (tailnet ${key})"
        fi
        continue
      fi
    fi

    # Pattern 2: direct proxy_pass http://host:port
    while IFS= read -r target; do
      [ -z "${target}" ] && continue
      local host="${target%:*}"
      local rport="${target##*:}"
      if echo "${host}" | grep -qE '^100\.|\.ts\.net$'; then
        local key="${host}:${rport}"
        local lport
        lport=$(alloc_port "${key}")
        ensure_socat "${key}" "${lport}"
        active_keys="${active_keys}${key}"$'\n'

        sed -i -E "s#(proxy_pass\s+https?://)${host}:${rport}#\\1127.0.0.1:${lport}#g" "${conf}"
        if ! grep -q "# tailnet-target: ${key}" "${conf}"; then
          sed -i "1i # tailnet-target: ${key} -> 127.0.0.1:${lport}" "${conf}"
        fi
        changed_any=1
        log "rewrote ${conf##*/} proxy_pass → 127.0.0.1:${lport} (tailnet ${key})"
      fi
    done < <(grep -oE 'proxy_pass\s+https?://[^;[:space:]]+' "${conf}" \
             | sed -E 's#proxy_pass\s+https?://##')
  done

  cleanup_stale "$(echo -n "${active_keys}" | sort -u)"

  if [ "${changed_any}" = "1" ]; then
    log "reloading nginx"
    # NPM's nginx binary lives at /usr/sbin/nginx
    /usr/sbin/nginx -s reload 2>/dev/null || log "nginx reload failed (nginx not up yet?)"
    # Update checksum so we don't loop on our own edits
    last_checksum=$(find "${CONF_DIR}" -type f -name '*.conf' -exec md5sum {} + 2>/dev/null | md5sum | awk '{print $1}')
  fi
}

log "watcher started, polling every ${POLL_INTERVAL}s"
while true; do
  process_configs || true
  sleep "${POLL_INTERVAL}"
done
