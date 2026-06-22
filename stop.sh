#!/bin/bash
# =============================================================================
#  stop.sh - tear down the Open5GS core network and undo all host changes.
#
#  Stops every NF and the WebUI, then removes the ogstun interface, the NAT
#  rule, and the external-mode virtual IP. Safe to run repeatedly.
#
#  (This also replaces the old stop_network_oai5g.sh wrapper, which did nothing
#  but call the stop script.)
# =============================================================================
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
load_env
ensure_sudo
detect_network

info "Stopping Open5GS core"

# 1. Processes and screen sessions.
sudo pkill -f 'open5gs-'   2>/dev/null || true
pkill -f 'webui.*npm'      2>/dev/null || true
pkill -f 'node.*server'    2>/dev/null || true
screen -X -S webui quit    2>/dev/null || true
for nf in nrf scp udr udm ausf pcf bsf nssf amf smf; do
  screen -X -S "$nf" quit  2>/dev/null || true
done
sudo screen -X -S upf quit 2>/dev/null || true
step "network functions and WebUI stopped"

# 2. Data-plane teardown.
sudo iptables -t nat -D POSTROUTING -s "$UE_SUBNET" ! -o ogstun -j MASQUERADE 2>/dev/null || true
sudo ip link delete ogstun  2>/dev/null || true
sudo ip link delete vrf-ogs  2>/dev/null || true
sudo ip netns delete core-ns 2>/dev/null || true
step "ogstun + NAT removed"

# 3. External-mode virtual IP.
if [ -n "${VNF_VI_IP:-}" ] && [ -n "${INF:-}" ] && ip addr show "$INF" | grep -q "$VNF_VI_IP"; then
  sudo ip addr del "$VNF_VI_IP/24" dev "$INF" 2>/dev/null || true
  step "virtual IP $VNF_VI_IP removed from $INF"
fi

info "Core fully stopped and cleaned up."
