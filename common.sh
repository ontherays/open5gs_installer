#!/bin/bash
# =============================================================================
#  lib/common.sh - shared helpers for the Open5GS control scripts.
#
#  Sourced by install.sh / start.sh / stop.sh / restart.sh / add-subscribers.sh.
#  Keeps the logging, sudo handling, network detection and config rendering in
#  one place so the individual scripts stay short and readable.
# =============================================================================

# Resolve the repo root from this file's location (lib/ lives one level down).
_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$_COMMON_DIR")"

# ----------------------------------------------------------------------------
# Logging
# ----------------------------------------------------------------------------
if [ -t 1 ]; then
  _C_BLUE=$'\033[34m'; _C_YELLOW=$'\033[33m'; _C_RED=$'\033[31m'
  _C_GREEN=$'\033[32m'; _C_DIM=$'\033[2m'; _C_RESET=$'\033[0m'
else
  _C_BLUE=; _C_YELLOW=; _C_RED=; _C_GREEN=; _C_DIM=; _C_RESET=
fi

info()  { printf '%s\n' "${_C_BLUE}==>${_C_RESET} $*"; }
step()  { printf '%s\n' "${_C_GREEN} -${_C_RESET} $*"; }
warn()  { printf '%s\n' "${_C_YELLOW}warning:${_C_RESET} $*" >&2; }
err()   { printf '%s\n' "${_C_RED}error:${_C_RESET} $*" >&2; }
die()   { err "$*"; exit 1; }

# ----------------------------------------------------------------------------
# Config
# ----------------------------------------------------------------------------
# Load open5gs.env. Pre-existing environment variables win, so inline overrides
# such as `MODE=external ./start.sh` keep working.
load_env() {
  local env_file="$REPO_ROOT/open5gs.env"
  [ -f "$env_file" ] || die "missing config file: $env_file"
  # shellcheck disable=SC1090
  source "$env_file"
}

# ----------------------------------------------------------------------------
# Privilege handling
#
# We never store a password. Instead we validate sudo once (prompting the user
# if needed) and keep the credential fresh in the background for the lifetime of
# the script - so long-running steps like the build don't stall on a re-prompt.
# ----------------------------------------------------------------------------
ensure_sudo() {
  if ! sudo -v; then
    die "this script needs sudo privileges (run as a user who can sudo)."
  fi
  # Refresh the cached timestamp every 50s until this script exits.
  ( while true; do sudo -n true 2>/dev/null; sleep 50; kill -0 "$$" 2>/dev/null || exit 0; done ) &
  _SUDO_KEEPALIVE_PID=$!
  trap '[ -n "${_SUDO_KEEPALIVE_PID:-}" ] && kill "$_SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT
}

# ----------------------------------------------------------------------------
# Network detection
#
# Fills in INF / NODE_IP / VNF_VI_IP when they were left blank in open5gs.env.
# ----------------------------------------------------------------------------
detect_network() {
  if [ -z "${INF:-}" ]; then
    INF="$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')"
    [ -z "$INF" ] && INF="$(ip -o link show up 2>/dev/null | awk -F': ' '$2!="lo"{print $2; exit}')"
  fi
  [ -n "${INF:-}" ] || die "could not determine a network interface; set INF in open5gs.env"

  if [ -z "${NODE_IP:-}" ]; then
    NODE_IP="$(ip -o -4 addr show dev "$INF" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
  fi

  if [ -z "${VNF_VI_IP:-}" ] && [ -n "${NODE_IP:-}" ]; then
    local prefix last
    prefix="$(echo "$NODE_IP" | cut -d. -f1-3)"
    last="$(echo "$NODE_IP" | cut -d. -f4)"
    VNF_VI_IP="${prefix}.$(( last + 1 ))"
  fi
}

# ----------------------------------------------------------------------------
# Config rendering
#
# Produces open5gs.yaml from the single template. The only thing that differs
# between local and external mode is where the four radio-facing functions bind:
# loopback in local mode, the host's physical IP in external mode.
# ----------------------------------------------------------------------------
render_config() {
  local out="$REPO_ROOT/open5gs.yaml"
  local mme amf sgwu upf
  if [ "${MODE:-local}" = "external" ]; then
    [ -n "${NODE_IP:-}" ] || die "external mode needs a NODE_IP (auto-detect failed; set it in open5gs.env)"
    mme="$NODE_IP"; amf="$NODE_IP"; sgwu="$NODE_IP"; upf="$NODE_IP"
  else
    mme=127.0.0.2; amf=127.0.0.5; sgwu=127.0.0.6; upf=127.0.0.7
  fi

  sed -e "s|@BASE_DIR@|$REPO_ROOT|g" \
      -e "s|@ADDR_MME_S1AP@|$mme|g" \
      -e "s|@ADDR_AMF_NGAP@|$amf|g" \
      -e "s|@ADDR_SGWU@|$sgwu|g" \
      -e "s|@ADDR_UPF@|$upf|g" \
      -e "s|@MCC@|${MCC}|g" \
      -e "s|@MNC@|${MNC}|g" \
      -e "s|@TAC@|${TAC}|g" \
      -e "s|@UE_SUBNET@|${UE_SUBNET}|g" \
      -e "s|@UE_GW@|${UE_GW}|g" \
      -e "s|@DNS1@|${DNS1}|g" \
      -e "s|@DNS2@|${DNS2}|g" \
      "$REPO_ROOT/templates/open5gs.yaml.template" > "$out"

  info "Rendered $out (mode=${MODE:-local})"
}
