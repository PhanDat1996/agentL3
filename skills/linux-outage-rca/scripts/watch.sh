#!/usr/bin/env bash
# watch.sh — lightweight "flight recorder" to catch an intermittent outage in the act.
#
# Every INTERVAL seconds it appends a compact snapshot (load, PSI, memory, top
# procs, D-state tasks, socket/conntrack counts, disk latency) to a size-capped
# log, and on a trigger (load, PSI, or free-mem threshold) also grabs a heavier
# snapshot. Writes only under LOGDIR. Runs as a transient systemd unit so it is
# easy to see and remove; nothing is installed or enabled at boot.
#
# This DOES run a process on the target, so it needs the client's OK first.
#
# Usage:
#   sudo bash watch.sh start [-i 10] [-d /var/tmp/rca-watch] [-m 200]   # -m = MB cap
#   sudo bash watch.sh stop
#   sudo bash watch.sh status
#   (internal) watch.sh loop ...

set -u
CMD=${1:-status}; shift || true
INTERVAL=10; LOGDIR=/var/tmp/rca-watch; CAP_MB=200
while getopts "i:d:m:" o; do
  case $o in i) INTERVAL=$OPTARG ;; d) LOGDIR=$OPTARG ;; m) CAP_MB=$OPTARG ;; *) exit 2 ;; esac
done
UNIT=rca-watch
SELF=$(readlink -f "$0")
NCPU=$(nproc)

snap_light() {
  echo "=== $(date '+%F %T') load=$(cut -d' ' -f1-3 /proc/loadavg)"
  for r in cpu memory io; do printf '%s %s\n' "psi-$r" "$(head -1 /proc/pressure/$r 2>/dev/null)"; done
  awk '/^(MemAvailable|MemFree|SwapFree|Dirty|Writeback|Slab|Shmem|Committed_AS):/{printf "%s %s ", $1, $2} END{print ""}' /proc/meminfo
  echo "fd $(cat /proc/sys/fs/file-nr) | conntrack $(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)/$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null) | tasks $(ls /proc | grep -c '^[0-9]')"
  ss -s 2>/dev/null | sed -n '1,2p'
  ps -eo pid,stat,pcpu,rss,comm --sort=-pcpu | head -6
  ps -eo pid,stat,wchan:30,comm | awk '$2 ~ /D/' | head -20 | sed 's/^/D: /'
}

snap_heavy() {
  echo "##### TRIGGERED HEAVY SNAPSHOT $(date '+%F %T')"
  top -b -n1 | head -40
  timeout 8 iostat -xmt 2 2 2>/dev/null | tail -n +1
  timeout 5 vmstat 1 3 2>/dev/null
  for p in $(ps -eo pid,stat | awk '$2 ~ /D/{print $1}' | head -10); do
    echo "--- stack of D-state pid $p ($(cat /proc/$p/comm 2>/dev/null))"; cat /proc/$p/stack 2>/dev/null
  done
  dmesg -T 2>/dev/null | tail -30
}

loop() {
  mkdir -p "$LOGDIR"
  local cap=$(( CAP_MB * 1024 * 1024 )) last_heavy=0
  while :; do
    local f="$LOGDIR/watch-$(date +%Y%m%d).log"
    snap_light >>"$f" 2>&1
    local load1 psi_mem avail now
    load1=$(cut -d' ' -f1 /proc/loadavg | cut -d. -f1)
    psi_mem=$(awk -F'avg10=' 'NR==1{split($2,a," "); print int(a[1])}' /proc/pressure/memory 2>/dev/null || echo 0)
    avail=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
    now=$(date +%s)
    if { [ "$load1" -ge $(( NCPU * 2 )) ] || [ "${psi_mem:-0}" -ge 20 ] || [ "$avail" -lt 200 ]; } && [ $(( now - last_heavy )) -ge 60 ]; then
      snap_heavy >>"$f" 2>&1; last_heavy=$now
    fi
    # size cap: drop oldest files until under cap
    while [ "$(du -sb "$LOGDIR" | cut -f1)" -gt "$cap" ]; do
      rm -f "$(ls -1tr "$LOGDIR"/watch-*.log | head -1)" || break
    done
    sleep "$INTERVAL"
  done
}

case $CMD in
  start)
    systemd-run --unit=$UNIT --description="RCA flight recorder (temporary)" \
      -p Nice=10 -p IOSchedulingClass=idle -p MemoryMax=64M \
      /bin/bash "$SELF" loop -i "$INTERVAL" -d "$LOGDIR" -m "$CAP_MB" \
      && echo "started; logs in $LOGDIR; stop with: sudo bash $SELF stop" ;;
  stop)   systemctl stop $UNIT && echo "stopped; logs kept in $LOGDIR" ;;
  status) systemctl status $UNIT --no-pager 2>&1 | head -5; ls -la "$LOGDIR" 2>/dev/null ;;
  loop)   loop ;;
  *) sed -n '2,18p' "$SELF" ;;
esac
