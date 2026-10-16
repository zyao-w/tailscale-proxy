#!/bin/bash
# ------------------------------------------------------------------------------
# autoforward.sh
#
# Watches NPM's generated nginx configs under /data/nginx/proxy_host/ and,
# for any upstream that points to a tailnet target (100.x.x.x or *.ts.net),
# automatically:
#   1. allocates a deterministic, collision-free local port
#   2. starts a socat bridge (HTTP CONNECT via tailscaled proxy) to the target
#   3. rewrites the .conf to use 127.0.0.1:<local-port>
#   4. reloads nginx
#
# Stale socat processes for targets no longer present are cleaned up.
# ------------------------------------------------------------------------------
set -u

CONF_DIR="/data/nginx/proxy_host"
STATE_DIR="/var/lib/tailscale"
STATE_FILE="${STATE_DIR}/autoforward.state"     # "host:port localport pid" per line
LOCK_FILE="${STATE_DIR}/autoforward.lock"
SOCKS_PORT="${TS_SOCKS_PORT:-1055}"
PORT_BASE=20000
PORT_RANGE=10000
POLL_INTERVAL=3

mkdir -p "${STATE_DIR}"
touch "${STATE_FILE}"

log() { echo "[autoforward] $*"; }

# ---------------------------------------------------------------------------
# Serialize all state-file mutations so concurrent/looped writes never clobber.
# ---------------------------------------------------------------------------
with_lock() {
  # Usage: with_lock <command...>
  if command -v flock >/dev/null 2>&1; then
    (
      flock -x 9
      "$@"
    ) 9>"${LOCK_FILE}"
  else
    "$@"
  fi
}

# ---------------------------------------------------------------------------
# Is a local TCP port currently listening? (busybox/no-ps friendly via /proc)
# ---------------------------------------------------------------------------
port_in_use() {
  local p="$1"
  # Try several detectors; succeed if any reports the port bound on loopback.
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep -qE "[:.]${p}\b" && return 0
  fi
  if command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | grep -qE "[:.]${p}\b" && return 0
  fi
  # /proc/net/tcp fallback: port is in hex, column 2 "local_address"
  local hexport
  hexport=$(printf '%04X' "${p}")
  if grep -qiE ":${hexport} " /proc/net/tcp 2>/dev/null; then
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Deterministic base port from "host:port" so restarts reuse the same slot.
# Uses only 7 hex chars (28-bit) to stay well within signed-int range,
# eliminating the negative-number overflow that caused port collisions.
# ---------------------------------------------------------------------------
base_port_for_key() {
  local key="$1"
  local hash
  hash=$(printf '%s' "${key}" | md5sum | awk '{print $1}')
  local num=$((16#${hash: -7}))        # 28-bit, always >= 0, never overflows
  echo $(( PORT_BASE + (num % PORT_RANGE) ))
}

# ---------------------------------------------------------------------------
# Allocate a concrete, collision-free port for a key.
# Starts at the deterministic base, then linearly probes forward, skipping:
#   - ports already assigned to a DIFFERENT key in the state file
#   - ports already bound/listening on the host
# If the key already has a recorded port, that port is reused as-is.
# ---------------------------------------------------------------------------
alloc_port() {
  local key="$1"

  # Reuse existing assignment if present.
  local existing
  existing=$(awk -v k="${key}" '$1==k {print $2; exit}' "${STATE_FILE}" 2>/dev/null)
  if [ -n "${existing}" ]; then
    echo "${existing}"
    return 0
  fi

  local base
  base=$(base_port_for_key "${key}")

  local i cand
  for i in $(seq 0 $((PORT_RANGE - 1))); do
    cand=$(( PORT_BASE + ((base - PORT_BASE + i) % PORT_RANGE) ))

    # Skip if another key already owns this port.
    if awk -v p="${cand}" -v k="${key}" '$2==p && $1!=k {found=1} END{exit !found}' \
         "${STATE_FILE}" 2>/dev/null; then
      continue
    fi
    # Skip if the port is currently bound by something else.
    if port_in_use "${cand}"; then
      continue
    fi
    echo "${cand}"
    return 0
  done

  # Range exhausted — fall back to base (should never happen in practice).
  echo "${base}"
}

# ---------------------------------------------------------------------------
# Record / replace a state line (lock-protected).
# ---------------------------------------------------------------------------
_write_state() {
  local key="$1" lport="$2" pid="$3"
  grep -v -E "^${key} " "${STATE_FILE}" > "${STATE_FILE}.tmp" 2>/dev/null || true
  echo "${key} ${lport} ${pid}" >> "${STATE_FILE}.tmp"
  mv "${STATE_FILE}.tmp" "${STATE_FILE}"
}

# ---------------------------------------------------------------------------
# Ensure a socat bridge for key -> 127.0.0.1:lport is running.
# Verifies the port actually comes up; retries once; logs failures loudly.
# ---------------------------------------------------------------------------
ensure_socat() {
  local key="$1"       # host:port
  local lport="$2"
  local host="${key%:*}"
  local rport="${key##*:}"

  # Already recorded and alive on the right port?
  local rec_lport rec_pid
  rec_lport=$(awk -v k="${key}" '$1==k {print $2; exit}' "${STATE_FILE}" 2>/dev/null)
  rec_pid=$(awk -v k="${key}" '$1==k {print $3; exit}' "${STATE_FILE}" 2>/dev/null)
  if [ "${rec_lport}" = "${lport}" ] && [ -n "${rec_pid}" ] \
     && kill -0 "${rec_pid}" 2>/dev/null && port_in_use "${lport}"; then
    return 0
  fi

  # If something stale is recorded, kill it before re-launching.
  if [ -n "${rec_pid}" ] && kill -0 "${rec_pid}" 2>/dev/null; then
    kill "${rec_pid}" 2>/dev/null || true
  fi

  local attempt pid ok=0
  for attempt in 1 2; do
    log "start socat 127.0.0.1:${lport} -> ${host}:${rport} (via HTTP CONNECT, attempt ${attempt})"
    socat TCP-LISTEN:${lport},fork,reuseaddr,bind=127.0.0.1 \
          PROXY:localhost:${host}:${rport},proxyport=${SOCKS_PORT} \
          >/dev/null 2>&1 &
    pid=$!

    # Give it a moment, then verify it's alive and listening.
    local w
    for w in 1 2 3 4 5; do
      if kill -0 "${pid}" 2>/dev/null && port_in_use "${lport}"; then
        ok=1
        break
      fi
      sleep 0.3
    done

    if [ "${ok}" = "1" ]; then
      break
    fi

    log "socat for ${key} failed to bind 127.0.0.1:${lport} (pid ${pid} dead or not listening)"
    kill "${pid}" 2>/dev/null || true
    sleep 0.5
  done

  if [ "${ok}" != "1" ]; then
    log "ERROR: giving up on socat for ${key} -> 127.0.0.1:${lport}"
    return 1
  fi

  with_lock _write_state "${key}" "${lport}" "${pid}"
  return 0
}

cleanup_stale() {
  local active_keys="$1"    # newline-separated list of host:port still in use
  _cleanup_impl() {
    local tmp="${STATE_FILE}.tmp"
    : > "${tmp}"
    while read -r line; do
      [ -z "${line}" ] && continue
      local key lport pid
      key=$(echo "${line}" | awk '{print $1}')
      lport=$(echo "${line}" | awk '{print $2}')
      pid=$(echo "${line}" | awk '{print $3}')
      if echo "${active_keys}" | grep -qxF "${key}"; then
        echo "${line}" >> "${tmp}"
      else
        log "stop socat for ${key} (pid ${pid})"
        kill "${pid}" 2>/dev/null || true
      fi
    done < "${STATE_FILE}"
    mv "${tmp}" "${STATE_FILE}"
  }
  with_lock _cleanup_impl
}

# ---------------------------------------------------------------------------
# Replace (or insert) the single tailnet-target marker as line 1.
# Removes any pre-existing marker lines first to avoid duplicate/stale markers.
# ---------------------------------------------------------------------------
set_marker() {
  local conf="$1" key="$2" lport="$3"
  sed -i -E '/^# tailnet-target: /d' "${conf}"
  sed -i "1i # tailnet-target: ${key} -> 127.0.0.1:${lport}" "${conf}"
}

last_checksum=""

process_configs() {
  [ -d "${CONF_DIR}" ] || return 0

  local checksum
  checksum=$(find "${CONF_DIR}" -type f -name '*.conf' -exec md5sum {} + 2>/dev/null | md5sum | awk '{print $1}')
  [ "${checksum}" = "${last_checksum}" ] && return 0
  last_checksum="${checksum}"

  log "config change detected, scanning ${CONF_DIR}"

  local active_keys=""
  local changed_any=0

  for conf in "${CONF_DIR}"/*.conf; do
    [ -f "${conf}" ] || continue

    # ---- Case A: conf already carries our marker ----
    local marker_line orig_key
    marker_line=$(grep -m1 -oE '^# tailnet-target: [^ ]+ -> 127\.0\.0\.1:[0-9]+' "${conf}" || true)
    if [ -n "${marker_line}" ]; then
      orig_key=$(echo "${marker_line}" | awk '{print $3}')
      local lport
      lport=$(alloc_port "${orig_key}")
      if ensure_socat "${orig_key}" "${lport}"; then
        active_keys="${active_keys}${orig_key}"$'\n'
      fi

      # Keep the conf's $server/$port in sync with the (reused) port.
      if ! grep -qE "set\s+\$server\s+\"127\.0\.0\.1\"" "${conf}" \
         || ! grep -qE "set\s+\$port\s+${lport}\b" "${conf}"; then
        sed -i -E "s#(set\s+\\\$server\s+)\"[^\"]+\"#\\1\"127.0.0.1\"#" "${conf}"
        sed -i -E "s#(set\s+\\\$port\s+)[0-9]+#\\1${lport}#" "${conf}"
        set_marker "${conf}" "${orig_key}" "${lport}"
        changed_any=1
        log "resynced ${conf##*/} -> 127.0.0.1:${lport} (tailnet ${orig_key})"
      fi
      continue
    fi

    # ---- Case B: fresh conf, Pattern 1 (set $server / set $port) ----
    local server port
    server=$(grep -oE 'set\s+\$server\s+"[^"]+"' "${conf}" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
    port=$(grep -oE 'set\s+\$port\s+[0-9]+' "${conf}" | head -1 | awk '{print $NF}')

    if [ -n "${server}" ] && [ -n "${port}" ]; then
      if echo "${server}" | grep -qE '^100\.|\.ts\.net$'; then
        local key="${server}:${port}"
        local lport
        lport=$(alloc_port "${key}")
        if ensure_socat "${key}" "${lport}"; then
          active_keys="${active_keys}${key}"$'\n'
          sed -i -E "s#(set\s+\\\$server\s+)\"[^\"]+\"#\\1\"127.0.0.1\"#" "${conf}"
          sed -i -E "s#(set\s+\\\$port\s+)[0-9]+#\\1${lport}#" "${conf}"
          set_marker "${conf}" "${key}" "${lport}"
          changed_any=1
          log "rewrote ${conf##*/} -> 127.0.0.1:${lport} (tailnet ${key})"
        fi
        continue
      fi
    fi

    # ---- Case C: Pattern 2 (direct proxy_pass http://host:port) ----
    local matched_any=0 primary_key="" primary_lport=""
    while IFS= read -r target; do
      [ -z "${target}" ] && continue
      local host="${target%:*}"
      local rport="${target##*:}"
      if echo "${host}" | grep -qE '^100\.|\.ts\.net$'; then
        local key="${host}:${rport}"
        local lport
        lport=$(alloc_port "${key}")
        if ensure_socat "${key}" "${lport}"; then
          active_keys="${active_keys}${key}"$'\n'
          sed -i -E "s#(proxy_pass\s+https?://)${host}:${rport}#\\1127.0.0.1:${lport}#g" "${conf}"
          if [ "${matched_any}" = "0" ]; then
            primary_key="${key}"; primary_lport="${lport}"; matched_any=1
          fi
          changed_any=1
          log "rewrote ${conf##*/} proxy_pass -> 127.0.0.1:${lport} (tailnet ${key})"
        fi
      fi
    done < <(grep -oE 'proxy_pass\s+https?://[^;[:space:]]+' "${conf}" \
             | sed -E 's#proxy_pass\s+https?://##')

    if [ "${matched_any}" = "1" ]; then
      set_marker "${conf}" "${primary_key}" "${primary_lport}"
    fi
  done

  cleanup_stale "$(printf '%s' "${active_keys}" | sort -u)"

  if [ "${changed_any}" = "1" ]; then
    log "reloading nginx"
    /usr/sbin/nginx -s reload 2>/dev/null || log "nginx reload failed (nginx not up yet?)"
    last_checksum=$(find "${CONF_DIR}" -type f -name '*.conf' -exec md5sum {} + 2>/dev/null | md5sum | awk '{print $1}')
  fi
}

log "watcher started, polling every ${POLL_INTERVAL}s"
while true; do
  process_configs || true
  sleep "${POLL_INTERVAL}"
done
