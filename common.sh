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

# TODO-BOLUN: Keep initial and boot-time Docker cache limits identical.
write_docker_config() {
  local mount=$1 path=$2
  cat >"$path.new" <<EOF
{
  "data-root": "$mount/docker",
  "builder": { "gc": { "enabled": true, "policy": [
    { "keepDuration": "48h", "reservedSpace": "4GB",
      "filter": ["type=source.local"] },
    { "keepDuration": "48h", "reservedSpace": "4GB",
      "filter": ["type=exec.cachemount"] },
    { "keepDuration": "48h", "reservedSpace": "4GB",
      "filter": ["type=source.git.checkout"] },
    { "keepDuration": "168h", "reservedSpace": "10GB", "maxUsedSpace": "60GB" },
    { "reservedSpace": "10GB", "maxUsedSpace": "60GB" },
    { "reservedSpace": "10GB", "maxUsedSpace": "80GB", "minFreeSpace": "100GB", "all": true }
  ] } }
}
EOF
  if ! dockerd --validate --config-file "$path.new"; then
    rm -f "$path.new"
    return 2
  fi
  if cmp -s "$path.new" "$path"; then
    rm -f "$path.new"
    return 1
  fi
  mv -f "$path.new" "$path"
}
