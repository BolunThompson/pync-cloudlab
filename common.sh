# shellcheck shell=bash
# Sourced by initial-setup.sh and boot-setup.sh.

die() { # print an error and exit nonzero (red startup status in the portal)
  echo "ERROR: $*" >&2
  exit 1
}

wait_for() { # <tries> <cmd...>: retry every 5s, die after <tries> failures
  local tries=$1
  shift
  local _
  for _ in $(seq "$tries"); do
    if "$@"; then return 0; fi
    sleep 5
  done
  die "timed out waiting for: $*"
}
