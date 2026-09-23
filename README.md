# CloudLab node setup

This repository is the CloudLab profile for PYNC. CloudLab checks it out at
`/local/repository` on each node. `initial-setup.sh` runs once per node;
`boot-setup.sh` runs on every boot. Profile changes require a portal profile
update and a new experiment to reach newly instantiated nodes. A local commit
alone does not update a running experiment.

## Storage layout

- `/mydata` is the mounted blockstore. Docker's `data-root` is
  `/mydata/docker`, and containerd's root is `/mydata/containerd`. Both services
  require that mount before starting. Provisioning removes abandoned
  `/var/lib/containerd` and removes `/var/lib/docker` only after Docker reports
  that its active root is under `/mydata`.
- Docker's BuildKit GC retains at least 10 GB for the broad rules, targets
  60 GB of cache, and has an 80 GB / 100 GB free-space backstop. Short-lived
  source and cache-mount records have their own 48-hour rule. The hourly
  `docker builder prune --filter until=6h` timer remains in place.
- `boot-setup.sh` reconciles `/etc/docker/daemon.json` and restarts Docker
  only when that file changes. The candidate config is checked with
  `dockerd --validate` before replacement.
- Each `/users/<user>/.docker` and `.cache` is a symlink to a private 0700
  directory under `/mydata/home-state/<user>`. This keeps client metadata and
  user caches local to each node even if `/users` is shared. Existing content
  is copied first. A failed copy is logged as a `NOTE` and setup continues.
  `~/.local` stays in the home directory because the uv installer uses it.
- The root-owned prune service uses
  `DOCKER_CONFIG=/mydata/home-state/root/.docker`.

## Diagnostics and setup contract

`disk-report.timer` records disk usage every ten minutes in
`/local/logs/disk-usage.log`. Each record includes filesystem space and inode
usage and `docker system df`. When the root filesystem reaches 80% usage, it
also walks its top-level directories with `du`. The log keeps its last 20,000
lines. Reporting only observes disk pressure; it does not abort a run or prune
anything in response.

The reporter is a separate systemd service so its output never enters
`/local/logs/setup.log`. The harness treats `ERROR:` in that setup log as a
fatal setup failure and waits for `SETUP-OK`. Setup prints a `NOTE` if the
reporter could not be installed.

On a node, inspect `systemctl status docker containerd disk-report.timer`,
`cat /etc/docker/daemon.json`, `findmnt -T /users`, and
`tail /local/logs/disk-usage.log` when investigating storage growth. The
filesystem backing `/users` must be checked before attributing a home-directory
`ENOSPC` to the root filesystem.
