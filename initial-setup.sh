#!/bin/bash

set -euo pipefail

ZELLIJ_VERSION=v0.44.3
HELIX_VERSION=25.07.1

REPO=/local/repository
MOUNT=/mydata
DONE_DIR=/local/setup-done.d

# shellcheck source=common.sh
. "$REPO/common.sh" # die

mkdir -p /local/logs "$DONE_DIR"
exec > >(tee -a /local/logs/setup.log) 2>&1
echo "=== initial-setup.sh ($(date -u +%FT%TZ)) ==="

# apt: install base packages and disable background updates.
setup_apt() {
  systemctl disable --now unattended-upgrades.service \
    apt-daily.timer apt-daily-upgrade.timer
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y nfs-common fish tmux git-lfs \
    curl xz-utils rsync
}

# install docker with its data-root on the persistent blockstore
install_docker() {
  if ! command -v docker >/dev/null; then
    curl -fsSL https://get.docker.com | sh
  fi
  mkdir -p "$MOUNT/docker" /etc/docker
  echo "{ \"data-root\": \"$MOUNT/docker\" }" >/etc/docker/daemon.json
  systemctl restart docker
}

# debugging tools: zellij + helix from pinned GitHub releases
install_tools() {
  curl -fsSL "https://github.com/zellij-org/zellij/releases/download/${ZELLIJ_VERSION}/zellij-x86_64-unknown-linux-musl.tar.gz" |
    tar -xz -C /usr/local/bin zellij
  chmod 0755 /usr/local/bin/zellij

  curl -fsSL "https://github.com/helix-editor/helix/releases/download/${HELIX_VERSION}/helix-${HELIX_VERSION}-x86_64-linux.tar.xz" |
    tar -xJ -C /opt
  ln -sfn "/opt/helix-${HELIX_VERSION}-x86_64-linux" /opt/helix
  ln -sf /opt/helix/hx /usr/local/bin/hx
}

main() {
  if [ -e "$DONE_DIR/initial" ]; then
    echo "initial-setup already done; nothing to do"
    exit 0
  fi

  setup_apt

  chmod 1777 "$MOUNT"

  install_docker
  install_tools

  touch "$DONE_DIR/initial"
  echo INITIAL-SETUP-OK
}

main "$@"
