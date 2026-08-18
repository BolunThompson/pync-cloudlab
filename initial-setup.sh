#!/bin/bash

set -euo pipefail

ZELLIJ_VERSION=v0.44.3
HELIX_VERSION=25.07.1

REPO=/local/repository
MOUNT=/mydata
DONE_DIR=/local/setup-done.d

# shellcheck source=common.sh
. "$REPO/common.sh" # die, wait_for

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
    curl xz-utils rsync ripgrep fd-find
}

# install docker with all of its state on the persistent blockstore.
# Docker >=29 keeps images AND the BuildKit cache in containerd's store, which
# `data-root` does NOT cover: without relocating containerd's root too, a few
# hours of image builds fill the 63GB system disk and every build then fails with
# "no space left on device" (BOL-208).
install_docker() {
  local unit
  if ! command -v docker >/dev/null; then
    curl -fsSL https://get.docker.com | sh
  fi
  mkdir -p "$MOUNT/docker" "$MOUNT/containerd" /etc/docker /etc/containerd
  cat >/etc/docker/daemon.json <<EOF
{
  "data-root": "$MOUNT/docker",
  "builder": { "gc": { "enabled": true, "policy": [ { "keepStorage": "50GB" } ] } }
}
EOF
  cat >/etc/containerd/config.toml <<EOF
disabled_plugins = ["cri"]
root = "$MOUNT/containerd"
EOF
  # Neither daemon may start before /mydata is mounted: it would write into the
  # mountpoint on the root disk, invisible to du once the blockstore mounts over it.
  for unit in docker containerd; do
    mkdir -p "/etc/systemd/system/$unit.service.d"
    printf '[Unit]\nRequiresMountsFor=%s\n' "$MOUNT" \
      >"/etc/systemd/system/$unit.service.d/mydata.conf"
  done
  systemctl daemon-reload
  systemctl stop docker.socket docker containerd
  systemctl start containerd docker
  wait_for 12 test -d "$MOUNT/containerd/io.containerd.content.v1.content"
  rm -rf /var/lib/containerd # relocated; anything left here only wastes root space
}

# belt-and-braces for BOL-208: trim build cache hourly, so a wedged gc cannot
# grow the store without bound over a multi-day eval
install_prune_timer() {
  cat >/etc/systemd/system/docker-prune.service <<'EOF'
[Unit]
Description=Trim the docker build cache
[Service]
Type=oneshot
ExecStart=/usr/bin/docker builder prune -f --filter until=6h
EOF
  cat >/etc/systemd/system/docker-prune.timer <<'EOF'
[Unit]
Description=Hourly docker build cache trim
[Timer]
OnBootSec=1h
OnUnitActiveSec=1h
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now docker-prune.timer
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

  # docker/containerd state lives here, so it must be the blockstore, not the
  # root disk sitting under an unmounted mountpoint
  mountpoint -q "$MOUNT" || die "blockstore not mounted at $MOUNT"
  chmod 1777 "$MOUNT"

  install_docker
  install_prune_timer
  install_tools

  touch "$DONE_DIR/initial"
  echo INITIAL-SETUP-OK
}

main "$@"
