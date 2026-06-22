#!/bin/bash
# =============================================================================
#  restart.sh - stop the core, then start it again in the requested mode.
#
#  Usage:
#      ./restart.sh [local|external] [cpu_list]
# =============================================================================
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
load_env

MODE="${1:-$MODE}"
[ "$MODE" = "local" ] || [ "$MODE" = "external" ] || die "usage: $0 [local|external] [cpu_list]"

info "Restarting Open5GS core (mode=$MODE)"
"$REPO_ROOT/stop.sh"
step "waiting 2s for ports and interfaces to release"
sleep 2
exec "$REPO_ROOT/start.sh" "$@"
