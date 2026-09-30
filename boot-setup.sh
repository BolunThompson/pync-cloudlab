#!/bin/bash

set -euo pipefail
shopt -s nullglob

REPO=/local/repository
MOUNT=/mydata
NFSDIR=/nfs
DONE_DIR=/local/setup-done.d

# shellcheck source=common.sh
. "$REPO/common.sh" # die, wait_for

mkdir -p /local/logs "$DONE_DIR"
exec > >(tee -a /local/logs/setup.log) 2>&1
echo "=== boot-setup.sh ($(date -u +%FT%TZ)) ==="

# verify the persistent blockstore is mounted (docker data-root depends on it)
setup_mount() {
  if ! mountpoint -q "$MOUNT"; then
    die "profile blockstore not mounted at $MOUNT"
  fi
  chmod 1777 "$MOUNT"
}

# TODO-BOLUN: Repair Docker GC settings on nodes provisioned before this profile revision.
reconcile_docker_config() {
  local status=0
  write_docker_config "$MOUNT" /etc/docker/daemon.json || status=$?
  case "$status" in
  0) systemctl try-restart docker ;;
  1) ;;
  *) die "could not validate Docker configuration" ;;
  esac
}

# BOL-208 guard: images and the BuildKit cache must sit on the blockstore. If
# they land on the 63GB root disk, a few hours of image builds fill it and every
# later build fails with "no space left on device".
docker_up() { docker info >/dev/null 2>&1; }
check_docker_storage() {
  local u
  wait_for 24 docker_up
  case "$(docker info --format '{{.DockerRootDir}}')" in
  "$MOUNT"/*) ;;
  *) die "docker data-root is not under $MOUNT" ;;
  esac
  grep -qx "root = \"$MOUNT/containerd\"" /etc/containerd/config.toml ||
    die "containerd root is not under $MOUNT"
  for u in /users/*; do
    [ -d "$u" ] || continue
    [ -L "$u/.docker" ] || echo "NOTE: $u/.docker is not relocated to $MOUNT"
  done
}

# add every user to the docker group (users can appear after first boot)
setup_docker_group() {
  local u
  for u in /users/*; do
    usermod -aG docker "$(basename "$u")"
  done
}

# TODO-BOLUN: Give each node local Docker and cache state even when /users is shared.
relocate_home_state() {
  local u user uid gid rel target source
  install -d -m 0755 "$MOUNT/home-state"
  for u in /users/*; do
    [ -d "$u" ] || continue
    user=$(basename "$u")
    uid=$(stat -c %u "$u")
    gid=$(stat -c %g "$u")
    install -d -m 0700 -o "$uid" -g "$gid" "$MOUNT/home-state/$user"
    for rel in .docker .cache; do
      source="$u/$rel"
      target="$MOUNT/home-state/$user/$rel"
      install -d -m 0700 -o "$uid" -g "$gid" "$target"
      if [ "$(readlink "$source" 2>/dev/null || true)" = "$target" ]; then continue; fi
      if [ -e "$source" ]; then
        cp -a "$source/." "$target/" || echo "NOTE: could not migrate $source; relinking anyway"
      fi
      install -d -m 0700 -o "$uid" -g "$gid" "$target"
      rm -rf "$source"
      ln -sfn "$target" "$source"
    done
  done
}

# uv, per user
install_uv() {
  local u user
  for u in /users/*; do
    user=$(basename "$u")
    if [ -x "$u/.local/bin/uv" ]; then continue; fi
    sudo -u "$user" env HOME="$u" sh -c \
      'curl -LsSf https://astral.sh/uv/install.sh | sh'
  done
}

# reproducible-performance settings: performance governor, turbo boost off
perf_settings() {
  local found g b

  # performance governor on all CPUs to prevent reducing the clock speed
  found=0
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    if ! echo performance >"$g"; then die "cannot set performance governor ($g)"; fi
    found=1
  done
  if [ "$found" != 1 ]; then echo "NOTE: no cpufreq governor interface on this node"; fi

  # disable turbo boost on all CPUs to prevent increasing the clock speed
  found=0
  for b in /sys/devices/system/cpu/cpufreq/boost \
    /sys/devices/system/cpu/cpufreq/policy*/boost; do
    if [ ! -f "$b" ]; then continue; fi
    if ! echo 0 >"$b"; then die "cannot disable CPU boost ($b)"; fi
    found=1
  done
  if [ "$found" != 1 ]; then echo "NOTE: no CPU boost control on this node"; fi
}

# /nfs is this node's own CloudLab-mounted dataset (a private rwclone for runs, or
# the real RW volume in populate mode). No NFS server/export -- each node has its
# own /nfs and the laptop orchestrates over ssh, so there is nothing to share.
setup_nfs() {
  local d
  if ! mountpoint -q "$NFSDIR"; then
    mkdir -p "$MOUNT/nfs" "$NFSDIR"
    mount --bind "$MOUNT/nfs" "$NFSDIR"
  fi
  chmod 1777 "$NFSDIR"
  for d in pync datasets results; do
    mkdir -p "$NFSDIR/$d"
    chmod 1777 "$NFSDIR/$d"
  done
}

# TODO-BOLUN: Record storage growth outside setup.log without stopping an evaluation.
install_disk_report() {
  install -m 0755 "$REPO/disk-report.sh" /usr/local/sbin/disk-report || return
  cat >/etc/systemd/system/disk-report.service <<'EOF' || return
[Unit]
Description=Record CloudLab node disk usage
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/disk-report
EOF
  cat >/etc/systemd/system/disk-report.timer <<'EOF' || return
[Unit]
Description=Record CloudLab node disk usage every ten minutes
[Timer]
OnBootSec=10min
OnUnitActiveSec=10min
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload || return
  systemctl enable --now disk-report.timer || return
  systemctl start disk-report.service || return
}

main() {
  # wait for cloudlab setup to finish
  wait_for 120 test -e "$DONE_DIR/initial"

  setup_mount
  reconcile_docker_config
  check_docker_storage
  setup_docker_group
  relocate_home_state
  install_uv
  perf_settings
  setup_nfs
  install_disk_report || echo "NOTE: disk reporting unavailable"

  echo SETUP-OK
}

main "$@"
