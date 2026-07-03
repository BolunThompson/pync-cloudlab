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

# add every user to the docker group (users can appear after first boot)
setup_docker_group() {
  local u
  for u in /users/*; do
    usermod -aG docker "$(basename "$u")"
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
  # wait for CloudLab to auto-mount the remote blockstore
  wait_for 30 mountpoint -q "$NFSDIR"
  chmod 1777 "$NFSDIR"
  for d in pync datasets results; do
    mkdir -p "$NFSDIR/$d"
    chmod 1777 "$NFSDIR/$d"
  done
}

main() {
  # wait for cloudlab setup to finish
  wait_for 120 test -e "$DONE_DIR/initial"

  setup_mount
  setup_docker_group
  install_uv
  perf_settings
  setup_nfs

  echo SETUP-OK
}

main "$@"
