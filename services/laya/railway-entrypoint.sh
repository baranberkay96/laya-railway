#!/bin/bash
# Laya HTTP API (laya-serve) on Railway, CPU only.
#
# Runs as root only long enough to:
#   1. refuse to start without a usable LAYA_API_KEY (laya-serve itself would serve unauthenticated),
#   2. bind laya-serve to PORT on every IPv4 and IPv6 address (LAYA_HOST empty, see below),
#   3. size torch's CPU threads from the service's cgroup CPU quota, capped at 8,
#   4. put the Hugging Face cache on the Railway volume and hand it to the "laya" user,
#   5. verify checkpoints against SHA-256 digests recorded for the reviewed revision,
# then drops to the "laya" user (UID 10001) and execs laya-serve through laya_railway.py.
set -euo pipefail

APP_USER=laya
APP_HOME=/home/laya
LAUNCHER=/opt/laya-railway/laya_railway.py
DIGESTS_FILE=/opt/laya-railway/reviewed-digests.json
CGROUP_ROOT=/sys/fs/cgroup
# Upper bound for the automatic thread count. Railway shows the host's cores (dozens) to every
# container; upstream measured the best CPU latency at about the physical core count, and
# oversubscribed threads stall under a smaller CPU quota. LAYA_THREADS overrides.
AUTO_THREAD_CAP=8
MIN_KEY_LENGTH=24

log() { printf '[laya-railway] %s\n' "$*" >&2; }
fail() { log "ERROR: $*"; exit 1; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
is_true() { case "$(lower "$1")" in 1|true|yes|on) return 0 ;; *) return 1 ;; esac; }

# --- 1. API key -------------------------------------------------------------------------------
check_api_key() {
  local key="${LAYA_API_KEY:-}"
  [[ -n "$key" ]] || fail "LAYA_API_KEY is empty. laya-serve would answer every request without authentication, so this template does not start. Set LAYA_API_KEY (${MIN_KEY_LENGTH}+ characters) and redeploy."
  (( ${#key} >= MIN_KEY_LENGTH )) || fail "LAYA_API_KEY must be at least ${MIN_KEY_LENGTH} characters long."
  [[ "$key" =~ ^[A-Za-z0-9._~+/=-]+$ ]] || fail "LAYA_API_KEY may contain only A-Z a-z 0-9 . _ ~ + / = - (it is sent in an HTTP header)."
}

# --- 2. Listener --------------------------------------------------------------------------------
configure_listener() {
  local port="${PORT:-${LAYA_PORT:-8080}}"
  if [[ ! "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    fail "PORT must be a TCP port number, got '$port'."
  fi
  # Railway's healthcheck probes PORT, so laya-serve listens there.
  export LAYA_PORT="$port"
  # laya-serve runs uvicorn with one worker; uvicorn hands LAYA_HOST to asyncio's create_server.
  # "::" would be IPv6-only and "0.0.0.0" IPv4-only; an empty host makes asyncio bind both
  # families, so Railway's IPv4 healthcheck and IPv6 private-network callers both connect.
  export LAYA_HOST="${LAYA_HOST:-}"
}

# --- 3. Threads -----------------------------------------------------------------------------------
# floor(quota/period) of the tightest CPU quota visible to this container (cgroup v2 cpu.max of
# its own cgroup and visible ancestors, then cgroup v1). Prints nothing when all are unlimited.
cgroup_cpu_limit() {
  local best="" quota period dir rel d
  consider() {
    [[ "$1" =~ ^[0-9]+$ && "$2" =~ ^[0-9]+$ ]] || return 0
    (( $2 > 0 )) || return 0
    local n=$(( $1 / $2 ))
    (( n < 1 )) && n=1
    if [[ -z "$best" ]] || (( n < best )); then best=$n; fi
  }
  if [[ -r "$CGROUP_ROOT/cgroup.controllers" ]]; then
    rel="$(awk -F: '$1 == "0" { print $3; exit }' /proc/self/cgroup 2>/dev/null || true)"
    dir="$CGROUP_ROOT${rel%/}"
    while [[ "$dir" == "$CGROUP_ROOT"* ]]; do
      if [[ -r "$dir/cpu.max" ]]; then
        read -r quota period < "$dir/cpu.max" && consider "$quota" "$period"
      fi
      [[ "$dir" == "$CGROUP_ROOT" ]] && break
      dir="$(dirname "$dir")"
    done
  fi
  for d in "$CGROUP_ROOT/cpu" "$CGROUP_ROOT/cpu,cpuacct" "$CGROUP_ROOT/cpuacct,cpu"; do
    if [[ -r "$d/cpu.cfs_quota_us" && -r "$d/cpu.cfs_period_us" ]]; then
      consider "$(cat "$d/cpu.cfs_quota_us")" "$(cat "$d/cpu.cfs_period_us")"
    fi
  done
  [[ -n "$best" ]] && echo "$best"
  return 0
}

configure_threads() {
  local n source
  if [[ "${LAYA_THREADS:-}" =~ ^[1-9][0-9]*$ ]]; then
    n="$LAYA_THREADS"; source="LAYA_THREADS"
  else
    [[ -z "${LAYA_THREADS:-}" ]] || log "ignoring LAYA_THREADS='${LAYA_THREADS}' (not a positive integer)"
    n="$(cgroup_cpu_limit)"
    if [[ -n "$n" ]]; then
      source="cgroup CPU quota $n"
    else
      n="$(nproc 2>/dev/null || echo 1)"; source="no CPU quota visible, visible CPUs $n"
    fi
    if (( n > AUTO_THREAD_CAP )); then n="$AUTO_THREAD_CAP"; source="$source, capped at $AUTO_THREAD_CAP"; fi
  fi
  export LAYA_THREADS="$n" OMP_NUM_THREADS="$n" MKL_NUM_THREADS="$n"
  THREAD_SOURCE="$source"
}

# --- 4. Model cache -----------------------------------------------------------------------------
configure_cache() {
  local data_dir="${RAILWAY_VOLUME_MOUNT_PATH:-/data}"
  export HF_HOME="${HF_HOME:-${data_dir%/}/huggingface}"
  if [[ -z "${RAILWAY_VOLUME_MOUNT_PATH:-}" ]]; then
    log "WARNING: no Railway volume is mounted; checkpoints are downloaded again after every redeploy. Attach a volume at /data."
  fi
  mkdir -p "$HF_HOME"
  if [[ "$(id -u)" == 0 ]]; then
    # A fresh Railway volume belongs to root. Re-own the cache only when needed: it holds
    # gigabytes of weights, and chown -R on every boot would be slow for nothing.
    if [[ "$(stat -c %U "$HF_HOME")" != "$APP_USER" ]]; then
      chown -R "$APP_USER:$APP_USER" "$HF_HOME"
    fi
    chmod 0755 "$(dirname "$HF_HOME")" 2>/dev/null || true
  elif [[ ! -w "$HF_HOME" ]]; then
    fail "HF_HOME=$HF_HOME is not writable by UID $(id -u)."
  fi
  local free_kb
  free_kb="$(df -Pk "$HF_HOME" 2>/dev/null | awk 'NR == 2 { print $4 }' || true)"
  [[ "$free_kb" =~ ^[0-9]+$ ]] || free_kb=0
  log "model cache $HF_HOME ($(( free_kb / 1048576 )) GB free)"
  [[ -n "${HF_TOKEN:-}" ]] || unset HF_TOKEN
}

# --- 5. Checkpoint digests ------------------------------------------------------------------------
configure_digests() {
  local reviewed="${TEMPLATE_DIGESTS_REVISION:-}"
  if ! is_true "${TEMPLATE_VERIFY_DIGESTS:-true}"; then
    log "checkpoint digests: off (TEMPLATE_VERIFY_DIGESTS)"
  elif [[ -n "${LAYA_SHA256_DIGESTS:-}" ]]; then
    log "checkpoint digests: your LAYA_SHA256_DIGESTS"
  elif [[ -n "${LAYA_EXTRA_MODELS:-}" ]]; then
    log "checkpoint digests: not applied, LAYA_EXTRA_MODELS may re-point a built-in checkpoint"
  elif [[ "${LAYA_REVISION:-}" == reviewed || ( -n "$reviewed" && "${LAYA_REVISION:-}" == "$reviewed" ) ]]; then
    LAYA_SHA256_DIGESTS="$(python -I -c 'import json, sys; print(json.dumps(json.load(open(sys.argv[1])), separators=(",", ":")))' "$DIGESTS_FILE")" \
      || fail "cannot read $DIGESTS_FILE"
    export LAYA_SHA256_DIGESTS
    log "checkpoint digests: SHA-256 of each checkpoint at revision ${reviewed:0:12} is checked before it loads"
  else
    log "checkpoint digests: not applied, they are recorded for LAYA_REVISION=reviewed only"
  fi
}

# --- Memory hint ----------------------------------------------------------------------------------
# Rough resident sizes on CPU: the checkpoints ship bf16 weights (english and typed-decisions
# 843 MB, multilingual 644 MB) that run as fp32 on CPU, plus tokenizer. Estimates, not measured.
checkpoint_mb() {
  case "$1" in
    multilingual|ml|multi) echo 1500 ;;
    *) echo 1800 ;;
  esac
}

memory_hint() {
  local limit="" models need=500 m
  limit="$(cat "$CGROUP_ROOT/memory.max" 2>/dev/null || true)"
  [[ "$limit" =~ ^[0-9]+$ ]] || return 0
  if ! is_true "${LAYA_PRELOAD:-1}"; then return 0; fi
  models="${LAYA_MODELS:-english,multilingual,typed-decisions}"
  for m in ${models//,/ }; do need=$(( need + $(checkpoint_mb "$(lower "$m")") )); done
  if (( limit / 1048576 < need )); then
    log "WARNING: this service may use $(( limit / 1048576 )) MB of RAM; preloading '$models' needs about $need MB. Raise the limit or preload less (LAYA_MODELS=multilingual)."
  fi
}

check_api_key
configure_listener
configure_threads
configure_cache
configure_digests
memory_hint

log "laya-serve on ${LAYA_HOST:-every IPv4 and IPv6 address} port $LAYA_PORT, device ${LAYA_DEVICE:-cpu}, models '${LAYA_MODELS:-all}', revision '${LAYA_REVISION:-hub default}', threads $LAYA_THREADS ($THREAD_SOURCE)"

cd "$APP_HOME"
if [[ "$(id -u)" == 0 ]]; then
  export HOME="$APP_HOME" USER="$APP_USER" LOGNAME="$APP_USER"
  exec setpriv --reuid="$APP_USER" --regid="$APP_USER" --init-groups python "$LAUNCHER"
fi
exec python "$LAUNCHER"
