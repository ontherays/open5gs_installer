#!/bin/bash
# =============================================================================
#  start.sh - bring up the Open5GS core network.
#
#  Renders the config for the chosen mode, sets up the ogstun data interface and
#  NAT, then launches each network function in its own detached screen session.
#
#  Usage:
#      ./start.sh [local|external] [cpu_list]
#
#      mode      defaults to MODE in open5gs.env (local).
#      cpu_list  optional taskset affinity for the NF processes, e.g. "2-7".
# =============================================================================
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
load_env

MODE="${1:-$MODE}"
CPUS="${2:-${CPUS:-}}"
[ "$MODE" = "local" ] || [ "$MODE" = "external" ] || die "usage: $0 [local|external] [cpu_list]"

BIN="$REPO_ROOT/open5gs/build/src"
CFG="$REPO_ROOT/open5gs.yaml"
LOG_DIR="$REPO_ROOT/open5gs_logs"
[ -x "$BIN/nrf/open5gs-nrfd" ] || die "Open5GS binaries not found - run ./install.sh first."

ensure_sudo
detect_network

info "Starting Open5GS core (mode=$MODE)"
step "interface : $INF"
step "node IP   : ${NODE_IP:-<none>}"
[ "$MODE" = "external" ] && step "gNB VIP   : $VNF_VI_IP"

# 1. Render open5gs.yaml for this mode.
render_config

# 2. Clean any leftovers from a previous run.
sudo ip link delete ogstun  2>/dev/null || true
sudo ip link delete vrf-ogs  2>/dev/null || true
sudo ip netns delete core-ns 2>/dev/null || true

# 3. External mode: give the gNB link a stable virtual IP on the NIC.
if [ "$MODE" = "external" ]; then
  if ip addr show "$INF" | grep -q "$VNF_VI_IP"; then
    step "virtual IP $VNF_VI_IP already present on $INF"
  else
    sudo ip addr add "$VNF_VI_IP/24" dev "$INF"
    step "added virtual IP $VNF_VI_IP to $INF"
  fi
fi

# 4. Data-plane interface (ogstun) for UE traffic + NAT to the outside world.
info "Configuring data plane (ogstun + NAT)"
sudo ip tuntap add name ogstun mode tun
sudo ip addr add "${UE_GW}/16" dev ogstun
sudo ip link set ogstun mtu 1400
sudo ip link set ogstun txqueuelen 10000
sudo ip link set ogstun up
sudo sysctl -wq net.ipv4.ip_forward=1
sudo iptables -t nat -D POSTROUTING -s "$UE_SUBNET" ! -o ogstun -j MASQUERADE 2>/dev/null || true
sudo iptables -t nat -A POSTROUTING -s "$UE_SUBNET" ! -o ogstun -j MASQUERADE
step "ogstun up (${UE_GW}/16), NAT for ${UE_SUBNET} configured"

# 5. Launch the 5G network functions, each in its own screen session.
#    Order matters: NRF and SCP first so the others can register.
info "Launching network functions"
mkdir -p "$LOG_DIR"
for nf in nrf scp udr udm ausf pcf bsf nssf amf smf; do
  screen -L -Logfile "$LOG_DIR/${nf}.log" -S "$nf" -dm "$BIN/$nf/open5gs-${nf}d" -c "$CFG"
  step "started $nf"
  sleep 0.5
done

# UPF owns the tun device, so it needs root. Its screen session is root-owned;
# attach to it with `sudo screen -r upf`.
sudo screen -L -Logfile "$LOG_DIR/upf.log" -S upf -dm "$BIN/upf/open5gs-upfd" -c "$CFG"
step "started upf (root)"

# 6. WebUI (Node app launched through nvm).
info "Launching WebUI on port ${WEBUI_PORT}"
WEBUI_HOST=$([ "$MODE" = "external" ] && echo "0.0.0.0" || echo "127.0.0.1")
screen -S webui -dm bash -lc '
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
  nvm use '"$NODE_VERSION"' >/dev/null
  cd "'"$REPO_ROOT"'/open5gs/webui"
  HOSTNAME='"$WEBUI_HOST"' PORT='"$WEBUI_PORT"' npm run dev
'

# 7. Optional CPU pinning.
if [ -n "$CPUS" ]; then
  info "Pinning NF processes to CPUs $CPUS"
  sleep 1
  for pid in $(pgrep '^open5gs-' || true); do
    sudo taskset -cp "$CPUS" "$pid" >/dev/null 2>&1 || true
  done
fi

info "Core is up. Sessions: $(screen -ls | grep -cE '\b(nrf|scp|udr|udm|ausf|pcf|bsf|nssf|amf|smf|webui)\b' || echo '?') user + 1 root (upf)"
step "list:    screen -ls"
step "attach:  screen -r amf        (or sudo screen -r upf)"
step "stop:    ./stop.sh"
