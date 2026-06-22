#!/bin/bash
# =============================================================================
#  install.sh - one-shot installer for the Open5GS core on Ubuntu.
#
#  Installs build dependencies and MongoDB, builds Open5GS from a pinned commit,
#  installs Node.js + the WebUI, and seeds a batch of test subscribers.
#
#  Everything configurable lives in open5gs.env (versions, commit pin, how many
#  subscribers to seed, ...). Run it from the repo root:
#
#      ./install.sh
# =============================================================================
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
load_env
ensure_sudo

cd "$REPO_ROOT"

# -----------------------------------------------------------------------------
# 1. System build dependencies
# -----------------------------------------------------------------------------
info "Checking build dependencies"
PACKAGES=(
  gnupg python3-pip python3-setuptools python3-wheel ninja-build gcc g++ flex
  bison git cmake libgnutls28-dev libgcrypt20-dev libssl-dev libidn11-dev
  libmongoc-dev libyaml-dev libnghttp2-dev libmicrohttpd-dev libcurl4-openssl-dev
  screen curl meson libsctp-dev libtalloc-dev
)
missing=()
for pkg in "${PACKAGES[@]}"; do
  dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed" || missing+=("$pkg")
done
if [ ${#missing[@]} -gt 0 ]; then
  step "Installing: ${missing[*]}"
  sudo apt-get update || true
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" \
    || warn "apt reported an error (possibly unrelated broken packages); continuing."
else
  step "All build dependencies already present."
fi

# -----------------------------------------------------------------------------
# 2. MongoDB
# -----------------------------------------------------------------------------
if ! dpkg-query -W -f='${Status}' mongodb-org 2>/dev/null | grep -q "ok installed"; then
  info "Installing MongoDB ${MONGODB_VERSION}"
  curl -fsSL "https://www.mongodb.org/static/pgp/server-${MONGODB_VERSION}.asc" \
    | sudo gpg -o "/usr/share/keyrings/mongodb-server-${MONGODB_VERSION}.gpg" --dearmor --batch --yes
  codename="$(lsb_release -cs)"
  echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-${MONGODB_VERSION}.gpg ] https://repo.mongodb.org/apt/ubuntu ${codename}/mongodb-org/${MONGODB_VERSION} multiverse" \
    | sudo tee "/etc/apt/sources.list.d/mongodb-org-${MONGODB_VERSION}.list" >/dev/null
  sudo apt-get update || true
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y mongodb-org \
    || warn "MongoDB install returned an error; continuing."
else
  step "MongoDB already installed."
fi

info "Starting MongoDB"
sudo systemctl daemon-reload || true
sudo systemctl enable --now mongod || true
for _ in $(seq 1 10); do
  if mongosh --quiet --eval "db.adminCommand('ping')" >/dev/null 2>&1; then
    step "MongoDB is up."
    break
  fi
  sleep 1
done

# -----------------------------------------------------------------------------
# 3. libyaml (built from source - matches the pinned Open5GS toolchain)
# -----------------------------------------------------------------------------
if [ ! -d yaml-0.1.7 ]; then
  info "Building libyaml 0.1.7"
  curl -fsSL -o yaml-0.1.7.tar.gz http://pyyaml.org/download/libyaml/yaml-0.1.7.tar.gz
  tar xf yaml-0.1.7.tar.gz
fi
( cd yaml-0.1.7
  [ -f Makefile ] || ./configure --prefix=/usr --disable-static
  make
  sudo make install )

# -----------------------------------------------------------------------------
# 4. Open5GS (pinned commit for reproducibility - see OPEN5GS_GIT_REF in env)
# -----------------------------------------------------------------------------
info "Building Open5GS @ ${OPEN5GS_GIT_REF}"
[ -d open5gs ] || git clone https://github.com/open5gs/open5gs
( cd open5gs
  git checkout "$OPEN5GS_GIT_REF"
  [ -d build ] || meson build --prefix="$(pwd)/install"
  ninja -C build )

# -----------------------------------------------------------------------------
# 5. Node.js + WebUI
# -----------------------------------------------------------------------------
info "Installing Node.js ${NODE_VERSION} (via nvm) and the WebUI"
if [ ! -d "$HOME/.nvm" ]; then
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.4/install.sh | bash
fi
export NVM_DIR="$HOME/.nvm"
# shellcheck disable=SC1091
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
nvm install "$NODE_VERSION"
nvm use "$NODE_VERSION"
( cd open5gs/webui && npm ci )

# -----------------------------------------------------------------------------
# 6. Seed subscribers (counter-based - see add-subscribers.sh)
# -----------------------------------------------------------------------------
info "Seeding ${SUB_COUNT} test subscriber(s)"
"$REPO_ROOT/add-subscribers.sh" seed

cat <<EOF

$(info "Installation complete.")
  Next:   ./start.sh            # local mode (loopback)
          ./start.sh external   # bind to physical IP for an external gNB
  WebUI:  http://localhost:${WEBUI_PORT}   (default login admin / 1423 - change it)
EOF
