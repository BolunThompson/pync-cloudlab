#!/bin/bash

set -uo pipefail

log=/local/logs/disk-usage.log
mkdir -p /local/logs
{
  date -u '+=== %FT%TZ ==='
  df -h / /mydata /nfs /users
  df -i / /mydata
  docker system df
  used=$(df -P / | awk 'NR == 2 { gsub(/%/, "", $5); print $5 }')
  if [[ $used =~ ^[0-9]+$ ]] && ((used >= 80)); then
    du -xh -d1 / 2>&1
  fi
} >>"$log" 2>&1

if [ "$(wc -l <"$log")" -gt 20000 ]; then
  tail -n 20000 "$log" >"$log.new" && mv -f "$log.new" "$log"
fi
