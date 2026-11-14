#!/usr/bin/env bash
# collect.sh — read-only evidence collector for intermittent Linux outages.
#
# Runs on the target host (RHEL/CentOS/Rocky/Alma/Ubuntu/Debian). Changes nothing:
# no package installs, no service restarts, no sysctl writes. Every command is
# best-effort and time-boxed so a hung NFS mount or slow disk cannot wedge it.
#
# Usage:  sudo bash collect.sh [-d DAYS] [-o OUTDIR] [-s SAMPLE_SECS] [-l PORTS] [-r] [-x TERMS_FILE]
#   -d  how many days of journal / sar history to pull (default 7)
#   -o  output parent dir (default /tmp)
#   -s  live sampling duration for vmstat/iostat/mpstat (default 30, 0 = skip)
#   -l  comma-separated ports the service should be listening on (Phase 1 check), e.g. 443,8088
#   -r  redact: pseudonymise hostnames, domains, IPs, MACs, emails, local users and
#       SSH fingerprints before packing. The token->value map stays on this host.
#   -x  extra terms to redact (one per line: customer/app names, ...); implies -r
# Output: OUTDIR/rca-<host>-<ts>.tar.gz  (rca-redacted-<ts>.tar.gz with -r)

set -u
export LC_ALL=C S_TIME_FORMAT=ISO   # 24h timestamps in sar, stable parsing
DAYS=7; OUT_PARENT=/tmp; SAMPLE=30; REDACT=0; TERMS=; PORTS=
while getopts "d:o:s:l:rx:h" o; do
  case $o in
    d) DAYS=$OPTARG ;; o) OUT_PARENT=$OPTARG ;; s) SAMPLE=$OPTARG ;;
    l) PORTS=$OPTARG ;; r) REDACT=1 ;; x) REDACT=1; TERMS=$OPTARG ;;
    *) sed -n '2,17p' "$0"; exit 0 ;;
  esac
done

HOST=$(hostname -s 2>/dev/null || cat /proc/sys/kernel/hostname)
TS=$(date +%Y%m%d-%H%M%S)
OUT="$OUT_PARENT/rca-$HOST-$TS"
mkdir -p "$OUT" || exit 1
SINCE="$(date -d "-$DAYS days" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$DAYS days ago")"
[ "$(id -u)" -eq 0 ] || echo "WARN: not root — dmesg, journal, crash dirs may be incomplete" | tee "$OUT/WARN-not-root.txt"

have() { command -v "$1" >/dev/null 2>&1; }
# run <file> <timeout-secs> <cmd...> : append labelled output, never fail
run() {
  local f=$1 t=$2; shift 2
  { echo "### $*"; timeout -k 2 "$t" "$@" 2>&1; echo "### rc=$?"; echo; } >>"$OUT/$f"
}
sh_run() { local f=$1 t=$2; shift 2; run "$f" "$t" bash -c "$*"; }
copy() { for p in "$@"; do [ -r "$p" ] && cp -a --parents "$p" "$OUT/files" 2>/dev/null; done; }
mkdir -p "$OUT/files"
echo "collecting into $OUT (since: $SINCE)"

# ---------- 01 identity / platform ----------
F=01-system.txt
run $F 5 date -R
run $F 5 uname -a
sh_run $F 5 'cat /etc/os-release; cat /etc/redhat-release 2>/dev/null'
run $F 5 uptime
sh_run $F 5 'cat /proc/cmdline'
have systemd-detect-virt && run $F 5 systemd-detect-virt
have dmidecode && sh_run $F 10 'dmidecode -s system-manufacturer; dmidecode -s system-product-name; dmidecode -s bios-version'
run $F 5 lscpu
have timedatectl && run $F 5 timedatectl
have chronyc && run $F 5 chronyc tracking
sh_run $F 5 'cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null'
sh_run $F 5 'cat /proc/sys/kernel/tainted; echo "(non-zero = tainted kernel)"'
have lsmod && sh_run $F 5 'lsmod | sort'

# ---------- 02 reboot / boot history (key for intermittent outages) ----------
F=02-boots.txt
sh_run $F 10 '{ last -x -F 2>/dev/null || wtmpdb last -x -F 2>/dev/null; } | grep -Ei "reboot|shutdown|crash|runlevel" | head -100'
have journalctl && run $F 10 journalctl --list-boots --no-pager
# How did each previous boot end? Clean shutdowns log "Reached target ... Shutdown"/"Power-Off".
if have journalctl; then
  for b in $(journalctl --list-boots --no-pager 2>/dev/null | awk '{print $1}' | grep -E '^-[0-9]+$' | tail -10); do
    sh_run $F 10 "echo '--- last 25 lines of boot $b ---'; journalctl -b $b -n 25 --no-pager -o short-iso"
  done
fi

# ---------- 03 kernel messages ----------
F=03-kernel.txt
run $F 10 dmesg -T --level=emerg,alert,crit,err,warn
run 03-dmesg-full.txt 10 dmesg -T
have journalctl && run 03-journal-kernel.txt 60 journalctl -k --since "$SINCE" --no-pager -o short-iso

# ---------- 04 journal / syslog ----------
if have journalctl; then
  run 04-journal-err.txt 90 journalctl -p warning --since "$SINCE" --no-pager -o short-iso
  run 04-journal-disk-usage.txt 10 journalctl --disk-usage
  sh_run 04-journal-disk-usage.txt 5 'test -d /var/log/journal && echo "journal storage: persistent" || echo "journal storage: volatile"'
fi
copy /var/log/messages /var/log/syslog /var/log/kern.log /var/log/dmesg /var/log/boot.log
for f in /var/log/messages-* /var/log/syslog.1 /var/log/kern.log.1; do copy "$f"; done
copy /var/log/mcelog /var/log/sa/sar* /var/log/sysstat/sar*

# ---------- 05 signature scan: the usual outage causes ----------
F=00-signals.txt
SIG='Out of memory|oom-kill|oom_reaper|Killed process|invoked oom-killer|hung_task|blocked for more than|soft lockup|hard LOCKUP|rcu_sched self-detected stall|rcu.*stall|Kernel panic|BUG:|Oops|general protection|Call Trace|watchdog: |NMI|Machine Check|mce:|EDAC|Hardware Error|I/O error|blk_update_request|Buffer I/O error|EXT4-fs error|XFS.*(error|corruption|Shutting down)|remount.*read-only|SCSI error|task abort|link is down|Link is Down|NETDEV WATCHDOG|tx timeout|nf_conntrack: table full|dropping packet|TCP: out of memory|possible SYN flooding|nfs: server .* not responding|page allocation failure|Too many open files|segfault|systemd-coredump|Started Process Core Dump|Watchdog timeout|Failed to start|entered failed state|Main process exited|temperature above threshold|thermal.*critical|throttl|clocksource.*unstable|time stamp counter|hv_balloon|vmw_balloon|virtio.*error'
{
  echo "# Known outage signatures, journal since $SINCE + full dmesg ring buffer (may be older)"
  echo
  src() { if have journalctl; then journalctl --since "$SINCE" --no-pager -o short-iso 2>/dev/null; else cat /var/log/messages /var/log/syslog /var/log/kern.log 2>/dev/null; fi; dmesg -T 2>/dev/null; }
  src | grep -Ei "$SIG" > "$OUT/.sig_hits" || true
  echo "## counts by signature"
  grep -oEi "$SIG" "$OUT/.sig_hits" | tr 'A-Z' 'a-z' | sort | uniq -c | sort -rn
  echo; echo "## last 300 hits"
  tail -300 "$OUT/.sig_hits"
} > "$OUT/$F" 2>&1
mv "$OUT/.sig_hits" "$OUT/05-signal-hits-all.txt"

# ---------- 06 memory ----------
F=06-memory.txt
run $F 5 free -m
sh_run $F 5 'cat /proc/meminfo'
sh_run $F 5 'grep -H . /proc/pressure/memory /proc/pressure/cpu /proc/pressure/io 2>/dev/null'
sh_run $F 5 'cat /proc/swaps; cat /proc/sys/vm/swappiness /proc/sys/vm/overcommit_memory /proc/sys/vm/min_free_kbytes'
have slabtop && sh_run $F 10 'slabtop -o -s c | head -30'
sh_run $F 10 'ps -eo pid,ppid,user,rss,vsz,pmem,pcpu,stat,lstart,comm --sort=-rss | head -40'
sh_run $F 10 'grep -H . /sys/fs/cgroup/*.slice/memory.events /sys/fs/cgroup/system.slice/*/memory.events 2>/dev/null | grep -v " 0$" | grep -E "oom|max" | head -100'

# ---------- 07 cpu / processes ----------
F=07-cpu-procs.txt
run $F 10 top -b -n 1 -o %CPU
sh_run $F 10 'ps -eo pid,user,pcpu,pmem,stat,wchan:32,lstart,args --sort=-pcpu | head -40'
sh_run $F 10 'echo "-- D-state (uninterruptible) tasks --"; ps -eo pid,stat,wchan:32,args | awk "\$2 ~ /D/"'
sh_run $F 5 'cat /proc/loadavg; echo; cat /proc/sys/kernel/pid_max /proc/sys/kernel/threads-max; echo nprocs=$(ls /proc | grep -c "^[0-9]")'
sh_run $F 5 'cat /proc/sys/fs/file-nr; cat /proc/sys/fs/file-max'
sh_run $F 5 'cat /proc/sys/kernel/hung_task_timeout_secs /proc/sys/kernel/panic /proc/sys/kernel/panic_on_oops /proc/sys/kernel/softlockup_panic 2>/dev/null'

# ---------- 08 disk / storage ----------
F=08-storage.txt
run $F 15 df -hT -x tmpfs -x devtmpfs
run $F 15 df -i -x tmpfs -x devtmpfs
run $F 10 lsblk -o NAME,KNAME,TYPE,SIZE,FSTYPE,MOUNTPOINT,MODEL,ROTA,SCHED
run $F 5 findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS
sh_run $F 5 'grep -E " (ro|ro,)" /proc/mounts | grep -vE "proc|sys|squashfs|iso9660|cgroup|tmpfs" || echo "no unexpected read-only mounts"'
have multipath && run $F 15 multipath -ll
have pvs && sh_run $F 15 'pvs; vgs; lvs -a'
have mdadm && sh_run $F 5 'cat /proc/mdstat'
have smartctl && sh_run $F 60 'for d in $(lsblk -dno NAME -e7,11); do echo "== $d"; smartctl -H -A /dev/$d | grep -Ei "result|Reallocated|Pending|Uncorrect|CRC|Wear|Media|Error" ; done'
sh_run $F 10 'cat /proc/diskstats'
sh_run $F 10 'grep -E "nfs|cifs" /proc/mounts || echo "no network filesystems"'

# ---------- 09 network ----------
F=09-network.txt
run $F 5 ip -br addr
run $F 5 ip -s -s link
run $F 5 ip route
run $F 5 ip rule
run $F 5 ss -s
sh_run $F 10 'ss -tan | awk "NR>1{print \$1}" | sort | uniq -c | sort -rn'
run $F 10 ss -ltnup
have nstat && run $F 5 nstat -az
sh_run $F 5 'cat /proc/net/softnet_stat'
sh_run $F 5 'echo conntrack $(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)/$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)'
have ethtool && sh_run $F 20 'for i in $(ls /sys/class/net | grep -v lo); do echo "== $i"; ethtool $i 2>/dev/null | grep -E "Speed|Duplex|Link detected"; ethtool -S $i 2>/dev/null | grep -iE "err|drop|miss|fifo|timeout|reset" | grep -v ": 0$"; done'
sh_run $F 5 'cat /etc/resolv.conf'
sh_run $F 5 'cat /proc/net/bonding/* 2>/dev/null || echo "no bonding"'

# ---------- 10 historical performance (sar) ----------
if have sar; then
  F=10-sar.txt
  for i in $(seq "$DAYS" -1 0); do
    d=$(date -d "-$i days" +%d 2>/dev/null) || continue
    for dir in /var/log/sa /var/log/sysstat; do
      f="$dir/sa$d"; [ -r "$f" ] || f="$dir/sa$(date -d "-$i days" +%Y%m%d)"; [ -r "$f" ] || continue
      sh_run $F 30 "echo '======== $f ========'; sar -q -f $f; sar -u -f $f; sar -r -f $f; sar -B -f $f; sar -W -f $f; sar -d -p -f $f | grep -v ' 0.00 *0.00 *0.00'; sar -n DEV -f $f | grep -vE \" (lo|veth[^ ]*|docker0|br-[^ ]*) \"; sar -n EDEV -f $f | grep -vE \" (lo|veth[^ ]*|br-[^ ]*) \""
    done
  done
else
  echo "sysstat (sar) not installed — no historical perf data. Recommend enabling it (see playbook)." > "$OUT/10-sar.txt"
fi

# ---------- 11 live sample ----------
if [ "$SAMPLE" -gt 0 ]; then
  F=11-live-sample.txt
  n=$(( SAMPLE / 5 )); [ $n -lt 1 ] && n=1
  have vmstat && timeout $((SAMPLE+10)) vmstat -t 5 $n >"$OUT/11-vmstat.txt" 2>&1 &
  have iostat && timeout $((SAMPLE+10)) iostat -xmt 5 $n >"$OUT/11-iostat.txt" 2>&1 &
  have mpstat && timeout $((SAMPLE+10)) mpstat -P ALL 5 $n >"$OUT/11-mpstat.txt" 2>&1 &
  wait
fi

# ---------- 12 services / systemd ----------
F=12-services.txt
if have systemctl; then
  run $F 10 systemctl --failed --no-pager
  run $F 10 systemctl list-units --type=service --state=running --no-pager
  run $F 10 systemctl list-timers --all --no-pager
  sh_run $F 30 'journalctl --since "'"$SINCE"'" --no-pager -o short-iso -u "*" 2>/dev/null | grep -E "Main process exited|Failed with result|Scheduled restart job|start request repeated too quickly" | tail -200'
  have coredumpctl && run $F 10 coredumpctl list --no-pager
fi
sh_run $F 5 'ls -la /etc/cron.d /var/spool/cron 2>/dev/null; cat /etc/crontab 2>/dev/null'

# ---------- 13 crash / kdump ----------
F=13-kdump.txt
sh_run $F 5 'cat /sys/kernel/kexec_crash_loaded /sys/kernel/kexec_crash_size 2>/dev/null; grep -o "crashkernel=[^ ]*" /proc/cmdline || echo "no crashkernel= on cmdline"'
have systemctl && sh_run $F 5 'systemctl is-enabled kdump kdump-tools 2>/dev/null; systemctl is-active kdump kdump-tools 2>/dev/null'
sh_run $F 5 'ls -laR /var/crash 2>/dev/null | head -100'
for d in /var/crash/*/; do copy "${d}vmcore-dmesg.txt" "${d}dmesg."*; done
copy /etc/kdump.conf /etc/default/kdump-tools

# ---------- 14 config / limits / recent changes ----------
F=14-config-changes.txt
run $F 10 sysctl -a
sh_run $F 5 'cat /etc/security/limits.conf /etc/security/limits.d/* 2>/dev/null | grep -v "^#" | grep -v "^$"'
sh_run $F 10 'if command -v rpm >/dev/null; then rpm -qa --last | head -60; fi'
sh_run $F 10 'grep -hE " (install|upgrade|remove) " /var/log/dpkg.log* 2>/dev/null | sort | tail -60'
sh_run $F 10 'grep -hE "Installed|Updated|Erased" /var/log/dnf.log* /var/log/yum.log* 2>/dev/null | tail -60'
copy /etc/sysctl.conf /etc/fstab /etc/default/grub
sh_run $F 5 'cat /etc/sysctl.d/*.conf 2>/dev/null | grep -v "^#" | grep -v "^$"'

# ---------- 15 security-relevant context (outage can be an attack) ----------
F=15-access.txt
sh_run $F 10 'last -F -n 50 2>/dev/null || wtmpdb last -F -n 50'
sh_run $F 10 'lastb -n 30 2>/dev/null | head -30'
sh_run $F 10 'journalctl --since "'"$SINCE"'" -u sshd -u ssh --no-pager 2>/dev/null | grep -c "Failed password" | sed "s/^/ssh failed-password count: /"'

# ---------- redaction (-r / -x) ----------
# One awk pass over every text file so tokens stay consistent across the bundle
# (IP_PRIV_3 is the same address everywhere). Loopback/any/broadcast addresses and
# systemd unit names (user@1000.service) are kept so the evidence stays readable.
# Best effort: anything not listed here (app names, paths) needs -x.
redact() {
  local terms="$OUT/.redact-terms" list="$OUT/.redact-files" f
  MAP="$OUT_PARENT/rca-redact-map-$TS.txt"
  {
    for h in "$(hostname -s 2>/dev/null)" "$(hostname -f 2>/dev/null)" "$(hostname 2>/dev/null)" "$HOST"; do
      printf 'HOST\t%s\n' "$h"
    done
    d=$(hostname -d 2>/dev/null); [ -n "$d" ] && printf 'DOMAIN\t%s\n' "$d"
    awk '/^(search|domain)[ \t]/{for(i=2;i<=NF;i++) print "DOMAIN\t" $i}' /etc/resolv.conf 2>/dev/null
    awk -F: '$3>=1000 && $3<65534 {print "USER\t" $1}' /etc/passwd
    [ -n "$TERMS" ] && [ -r "$TERMS" ] && grep -v '^[[:space:]]*$' "$TERMS" | sed 's/^/TERM\t/'
  } | awk -F'\t' 'length($2)>=3 && $2!="localhost" && $2!="localdomain" && !seen[$2]++ {print length($2) "\t" $0}' \
    | sort -rn | cut -f2- > "$terms"
  find "$OUT" -type f ! -name '.redact-*' -exec grep -Il . {} + > "$list" 2>/dev/null
  # shellcheck disable=SC2046
  awk -F'\t' -v mapfile="$MAP" '
    function tok(kind, v,   k) {
      k = kind SUBSEP v
      if (!(k in map)) { cnt[kind]++; map[k] = kind "_" cnt[kind]; rows[++n] = map[k] "\t" v }
      return map[k]
    }
    function wc(c) { return c ~ /[A-Za-z0-9_]/ }
    function lit(s, from, to,   out, i, L, pre) {
      out = ""; L = length(from)
      while ((i = index(s, from)) > 0) {
        pre = (i > 1) ? substr(s, i-1, 1) : ""
        if (!wc(pre) && !wc(substr(s, i+L, 1))) out = out substr(s, 1, i-1) to
        else out = out substr(s, 1, i-1+L)
        s = substr(s, i+L)
      }
      return out s
    }
    function ip4(m, pre, post,   o, i) {
      if (pre ~ /[A-Za-z0-9._-]/ || post ~ /[A-Za-z0-9_-]/) return m
      split(m, o, "."); for (i = 1; i <= 4; i++) if (o[i] + 0 > 255) return m
      if (o[1] == 127 || m == "0.0.0.0" || o[1] == 255 || m ~ /^255\./) return m
      if (o[1] == 10 || (o[1] == 192 && o[2] == 168) || (o[1] == 172 && o[2] >= 16 && o[2] <= 31) \
          || (o[1] == 169 && o[2] == 254) || (o[1] == 100 && o[2] >= 64 && o[2] <= 127))
        return tok("IP_PRIV", m)
      return tok("IP_PUB", m)
    }
    function one(kind, m, pre, post) {
      if (kind == "IP4") return ip4(m, pre, post)
      if (kind == "EMAIL") return (m ~ /\.(service|socket|timer|mount|target|slice|scope|path|device|swap|automount)$/) ? m : tok("EMAIL", m)
      if (kind == "MAC") return (m ~ /^(ff:ff:ff:ff:ff:ff|00:00:00:00:00:00)$/) ? m : tok("MAC", tolower(m))
      if (kind == "IP6") return (gsub(/:/, ":", m) >= 2 && pre !~ /[A-Za-z0-9_]/) ? tok("IP6", m) : m
      return tok(kind, m)
    }
    function rx(s, re, kind,   out, m, pre) {
      out = ""
      while (match(s, re)) {
        m = substr(s, RSTART, RLENGTH); pre = (RSTART > 1) ? substr(s, RSTART-1, 1) : ""
        out = out substr(s, 1, RSTART-1) one(kind, m, pre, substr(s, RSTART+RLENGTH, 1))
        s = substr(s, RSTART+RLENGTH)
      }
      return out s
    }
    NR == FNR && FILENAME ~ /\.redact-terms$/ { tk[++nt] = $1; tv[nt] = $2; next }
    FNR == 1 { if (outf) close(outf); outf = FILENAME ".red" }
    {
      s = $0
      s = rx(s, "SHA256:[A-Za-z0-9+/]+", "FP")
      s = rx(s, "[A-Za-z0-9._%+-]+@[A-Za-z][A-Za-z0-9.-]*\\.[A-Za-z][A-Za-z]+", "EMAIL")
      s = rx(s, "[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]", "MAC")
      s = rx(s, "[23][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f:]*:[0-9A-Fa-f]+", "IP6")
      s = rx(s, "[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+", "IP4")
      for (i = 1; i <= nt; i++) if (index(s, tv[i])) s = lit(s, tv[i], tok(tk[i], tv[i]))
      print s > outf
    }
    END { if (outf) close(outf); for (i = 1; i <= n; i++) print rows[i] > mapfile }
  ' "$terms" $(cat "$list")
  while read -r f; do mv -f "$f.red" "$f"; done < "$list"
  rm -f "$terms" "$list"; chmod 600 "$MAP" 2>/dev/null
  # hostname is also in the directory name
  mv "$OUT" "$OUT_PARENT/rca-redacted-$TS" && OUT="$OUT_PARENT/rca-redacted-$TS"
  echo "REDACTED bundle: identifiers replaced by tokens (HOST_n, IP_PRIV_n, USER_n, ...). Map kept on host only." > "$OUT/REDACTED.txt"
}

# ---------- manifest & pack ----------
{
  echo "host=$HOST collected=$(date -R) since=\"$SINCE\" days=$DAYS sample=$SAMPLE uid=$(id -u)"
  echo "tools: $(for t in journalctl sar iostat vmstat mpstat perf crash kdumpctl smartctl ethtool nstat multipath; do have $t && printf '%s ' $t; done)"
  [ -n "$PORTS" ] && echo "expected_ports=$PORTS"
  echo "missing: $(for t in journalctl sar iostat vmstat mpstat perf crash smartctl ethtool nstat; do have $t || printf '%s ' $t; done)"
} > "$OUT/MANIFEST.txt"
# Phase 1 report (statistics + checks) if phase1-report.sh was copied alongside
HERE=$(cd "$(dirname "$0")" && pwd)
if [ -r "$HERE/phase1-report.sh" ]; then
  bash "$HERE/phase1-report.sh" "$OUT" | sed 's/^/  /'
  [ -r "$HERE/../templates/phase1.xsl" ] && cp "$HERE/../templates/phase1.xsl" "$OUT/"
  [ -r "$HERE/phase1.xsl" ] && cp "$HERE/phase1.xsl" "$OUT/"
else
  echo "  (phase1-report.sh not next to collect.sh: run it later on the bundle)"
fi
[ "$REDACT" -eq 1 ] && redact
tar -C "$OUT_PARENT" -czf "$OUT.tar.gz" "$(basename "$OUT")" 2>/dev/null
echo "done: $OUT.tar.gz ($(du -h "$OUT.tar.gz" | cut -f1))"
[ "$REDACT" -eq 1 ] && echo "redaction map (keep private, do NOT send): $MAP"
