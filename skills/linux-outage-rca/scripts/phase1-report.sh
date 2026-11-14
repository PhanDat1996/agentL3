#!/usr/bin/env bash
# phase1-report.sh — Phase 1 report: statistics + CIS-style health checks, as XML.
#
# Reads ONLY an evidence bundle produced by collect.sh (no live commands), so it
# runs the same on the target, on an offline analysis box, or on an old bundle.
# Pure bash + POSIX awk (mawk / BWK / gawk); no python, no xmllint needed.
#
# Usage: bash phase1-report.sh BUNDLE_DIR [OUT.xml]
#        (default output: BUNDLE_DIR/phase1-report.xml)
# Render: xsltproc phase1.xsl phase1-report.xml > phase1-report.html

set -u
export LC_ALL=C
B=${1:?usage: phase1-report.sh BUNDLE_DIR [OUT.xml]}
XML=${2:-$B/phase1-report.xml}
[ -r "$B/MANIFEST.txt" ] || { echo "not a collect.sh bundle: $B" >&2; exit 1; }
VERSION=1.0

# ---------- helpers ----------
# section KEY FILE : output lines of the "### <cmd containing KEY>" block
section() { awk -v k="$1" '/^### rc=/{ins=0; next} /^### /{ins=(index($0,k)>0); next} ins' "$2" 2>/dev/null; }
esc() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"; }
e() { printf '%s' "$1" | esc; }
num() { case "$1" in ''|*[!0-9.]*) echo 0 ;; *) echo "$1" ;; esac; }
# float compare: fgt A B -> true if A > B
fgt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 > b+0)}'; }
# awk prelude: xa() escapes a string for an XML attribute
XA='function xa(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); gsub(/"/, "\\&quot;", s); return s } '
pct() { awk -v a="$1" -v b="$2" 'BEGIN{ if (b+0 > 0) printf "%.1f", 100*a/b; else print 0 }'; }

CHECKS=$(mktemp); STATS=$(mktemp); trap 'rm -f "$CHECKS" "$STATS"' EXIT
NP=0; NW=0; NF=0; NN=0
# check ID SEVERITY CATEGORY RESULT "TITLE" "VALUE" "EXPECTED" "EVIDENCE" "ADVICE"
check() {
  case $4 in pass) NP=$((NP+1)) ;; warn) NW=$((NW+1)) ;; fail) NF=$((NF+1)) ;; *) NN=$((NN+1)) ;; esac
  {
    printf '    <check id="%s" severity="%s" category="%s" result="%s">\n' "$1" "$2" "$3" "$4"
    printf '      <title>%s</title>\n' "$(e "$5")"
    printf '      <observed>%s</observed>\n' "$(e "$6")"
    printf '      <expected>%s</expected>\n' "$(e "$7")"
    printf '      <evidence>%s</evidence>\n' "$(e "$8")"
    [ -n "${9:-}" ] && printf '      <advice>%s</advice>\n' "$(e "$9")"
    printf '    </check>\n'
  } >> "$CHECKS"
}

# ---------- host facts ----------
HOST=$(sed -n 's/^host=\([^ ]*\).*/\1/p' "$B/MANIFEST.txt")
COLLECTED=$(sed -n 's/.* collected=\(.*\) since=.*/\1/p' "$B/MANIFEST.txt")
SINCE=$(sed -n 's/.* since="\([^"]*\)".*/\1/p' "$B/MANIFEST.txt")
DAYS=$(sed -n 's/.* days=\([0-9]*\).*/\1/p' "$B/MANIFEST.txt")
OS=$(sed -n 's/^PRETTY_NAME="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$B/01-system.txt" | head -1)
KERNEL=$(section "uname -a" "$B/01-system.txt" | awk '{print $3}' | head -1)
UPTIME=$(section "### uptime" "$B/01-system.txt" | head -1; true)
[ -z "$UPTIME" ] && UPTIME=$(awk '/^### uptime/{getline; print; exit}' "$B/01-system.txt")
VIRT=$(awk '/^### systemd-detect-virt/{getline; print; exit}' "$B/01-system.txt")
NCPU=$(awk -F: '/^CPU\(s\):/{gsub(/ /,"",$2); print $2; exit}' "$B/01-system.txt"); NCPU=$(num "${NCPU:-1}"); [ "$NCPU" = 0 ] && NCPU=1
REDACTED=false; [ -e "$B/REDACTED.txt" ] && REDACTED=true

# ---------- event statistics from the signature hits ----------
# Kernel lines exist twice (journal + dmesg); count journal-format lines when present.
HITS="$B/05-signal-hits-all.txt"
awk '
  function cat_of(l) {
    if (l ~ /Killed process/) return "oom"          # one line per kill
    if (l ~ /invoked oom-killer|oom-kill:|Out of memory/) return ""
    if (l ~ /blocked for more than|hung_task/) return "hung_task"
    if (l ~ /soft lockup|hard LOCKUP|rcu.*stall/) return "cpu_stall"
    if (l ~ /Kernel panic|BUG:|Oops|general protection/) return "kernel_crash"
    if (l ~ /Machine Check|mce:|Hardware Error|EDAC.*(error|CE|UE)/) return "hardware"
    if (l ~ /I\/O error|blk_update_request|SCSI error|task abort/) return "io_error"
    if (l ~ /EXT4-fs error|XFS.*(error|corruption|Shutting down)|remount.*read-only|Remounting filesystem read-only/) return "filesystem"
    if (l ~ /nfs: server .* not responding/) return "nfs"
    if (l ~ /[Ll]ink is [Dd]own|NETDEV WATCHDOG|tx timeout|nf_conntrack: table full|possible SYN flooding|TCP: out of memory|dropping packet/) return "network"
    if (l ~ /Too many open files|page allocation failure/) return "resource_limit"
    if (l ~ /segfault|systemd-coredump|Process Core Dump/) return "crash_dump"
    if (l ~ /Main process exited|Failed to start|entered failed state|Watchdog timeout/) return "service_failure"
    if (l ~ /clocksource.*unstable|time stamp counter|hv_balloon|vmw_balloon/) return "virtualization"
    if (l ~ /temperature above threshold|thermal.*critical|throttl/) return "thermal"
    return ""
  }
  { lines[NR] = $0; if ($0 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T/) iso = 1 }
  END {
    for (i = 1; i <= NR; i++) {
      l = lines[i]
      if (iso && l !~ /^[0-9][0-9][0-9][0-9]-/) continue
      c = cat_of(l); if (c == "") continue
      ts = (l ~ /^\[/) ? substr(l, 2, index(l, "]") - 2) : substr(l, 1, 19)
      n[c]++; if (!(c in first)) first[c] = ts; last[c] = ts
      if (c == "oom" && match(l, /Killed process [0-9]+ \([^)]*\)/)) {
        s = substr(l, RSTART, RLENGTH); sub(/^[^(]*\(/, "", s); sub(/\)$/, "", s); victim[s]++
      }
    }
    for (c in n) printf "EV\t%s\t%d\t%s\t%s\n", c, n[c], first[c], last[c]
    for (v in victim) printf "OOMV\t%s\t%d\n", v, victim[v]
  }' "$HITS" 2>/dev/null | sort > "$STATS.ev"
evc() { awk -F'\t' -v c="$1" '$1=="EV" && $2==c {print $3; f=1} END{if(!f) print 0}' "$STATS.ev"; }
evlast() { awk -F'\t' -v c="$1" '$1=="EV" && $2==c {print $5}' "$STATS.ev"; }

# ---------- service failures / restarts per unit ----------
grep -hE "Failed with result|Scheduled restart job|Main process exited" "$B/12-services.txt" 2>/dev/null \
 | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /\.(service|scope|socket|timer|mount):$/) { u = $i; sub(/:$/, "", u) }
         if (u == "") next
         if ($0 ~ /Scheduled restart job/) r[u]++; else if ($0 ~ /Failed with result/) { f[u]++; if (match($0, /result .[a-z-]+./)) why[u] = substr($0, RSTART+8, RLENGTH-9) }
         seen[u] = 1; u = "" }
        END { for (u in seen) printf "SVC\t%s\t%d\t%d\t%s\n", u, f[u]+0, r[u]+0, why[u] }' | sort -t"$(printf '\t')" -k3,3nr > "$STATS.svc"
FAILED_UNITS=$(section "systemctl --failed" "$B/12-services.txt" | awk '/loaded units listed/{print $1}' | head -1); FAILED_UNITS=$(num "${FAILED_UNITS:-0}")
COREDUMPS=$(section "coredumpctl list" "$B/12-services.txt" | grep -cvE "^TIME|No coredumps|^$" ); COREDUMPS=$(num "$COREDUMPS")

# ---------- boots ----------
BOOTS=$(section "list-boots" "$B/02-boots.txt" | grep -cE "^ *-?[0-9]+ +[0-9a-f]{32}")
UNCLEAN=$(awk '/^--- last 25 lines of boot/{if (b && !clean) u++; b=1; clean=0} /Reached target.*(Power-Off|Shutdown|Reboot|Final)|systemd-shutdown|Journal stopped/{clean=1} END{if (b && !clean) u++; print u+0}' "$B/02-boots.txt")

# ---------- memory / pressure ----------
mi() { awk -v k="$1:" '$1==k{print $2; exit}' "$B/06-memory.txt"; }
MEMT=$(num "$(mi MemTotal)"); MEMA=$(num "$(mi MemAvailable)"); SWT=$(num "$(mi SwapTotal)"); SWF=$(num "$(mi SwapFree)")
MEMA_PCT=$(pct "$MEMA" "$MEMT"); SWU_PCT=$(pct "$((SWT-SWF))" "$SWT")
psi() { # psi RESOURCE KIND -> avg300 (handles labelled "/proc/pressure/x:some ..." and unlabelled order)
  awk -v r="$1" -v k="$2" '
    index($0, "/proc/pressure/" r ":" k) == 1 { for (i = 1; i <= NF; i++) if ($i ~ /^avg300=/) { sub(/avg300=/, "", $i); print $i; exit } }' "$B/06-memory.txt"; }
PSI_MEM=$(num "$(psi memory full)"); PSI_IO=$(num "$(psi io full)"); PSI_CPU=$(num "$(psi cpu some)")

# ---------- cpu / processes / limits ----------
LOADLINE=$(grep -m1 -E "^[0-9.]+ [0-9.]+ [0-9.]+ [0-9]+/[0-9]+ [0-9]+$" "$B/07-cpu-procs.txt")
LOAD1=$(echo "$LOADLINE" | awk '{print $1}'); LOAD15=$(echo "$LOADLINE" | awk '{print $3}')
DSTATE=$(awk '/-- D-state/{f=1; next} /^### rc=/{f=0} f && $2 ~ /D/' "$B/07-cpu-procs.txt" | wc -l | tr -d ' ')
FDLINE=$(section "file-nr" "$B/07-cpu-procs.txt" | head -2 | tr '\n' ' ')
FD_USED=$(echo "$FDLINE" | awk '{print $1}'); FD_MAX=$(echo "$FDLINE" | awk '{print $4}')
FD_PCT=$(pct "$(num "$FD_USED")" "$(num "$FD_MAX")")
TAINT=$(awk '/kernel\/tainted/{getline; print; exit}' "$B/01-system.txt"); TAINT=$(num "$TAINT")

# ---------- storage ----------
section "df -hT" "$B/08-storage.txt" | awk 'NR>1 && $6 ~ /%$/ {p=$6; sub(/%/,"",p); print p "\t" $7 "\t" $1}' | sort -rn > "$STATS.df"
section "df -i" "$B/08-storage.txt" | awk 'NR>1 && $5 ~ /%$/ {p=$5; sub(/%/,"",p); print p "\t" $6}' | sort -rn > "$STATS.di"
DF_MAX=$(head -1 "$STATS.df" | cut -f1); DF_MAX=$(num "${DF_MAX:-0}"); DF_MNT=$(head -1 "$STATS.df" | cut -f2)
DI_MAX=$(head -1 "$STATS.di" | cut -f1); DI_MAX=$(num "${DI_MAX:-0}"); DI_MNT=$(head -1 "$STATS.di" | cut -f2)
RO_MOUNTS=$(section "/proc/mounts | grep -vE" "$B/08-storage.txt" | grep -vc "no unexpected read-only")

# ---------- network ----------
CT=$(sed -n 's/^conntrack \([0-9]*\)\/\([0-9]*\)$/\1 \2/p' "$B/09-network.txt")
CT_PCT=$(pct "$(echo "$CT" | awk '{print $1+0}')" "$(echo "$CT" | awk '{print $2+0}')")
SOFTNET_DROPS=$(section "softnet_stat" "$B/09-network.txt" | awk '
  function h(x,  i, c, v) { v = 0; x = tolower(x); for (i = 1; i <= length(x); i++) { c = index("0123456789abcdef", substr(x, i, 1)) - 1; v = v * 16 + c } return v }
  NF >= 3 { d += h($2) } END { print d+0 }')
nst() { awk -v k="$1" '$1==k{print $2; exit}' "$B/09-network.txt"; }
LISTEN_OVF=$(num "$(nst TcpExtListenOverflows)"); LISTEN_DROP=$(num "$(nst TcpExtListenDrops)")
NIC_ERR=$(section "ethtool -S" "$B/09-network.txt" | grep -cE ":[[:space:]]*[1-9]")

# ---------- historical maxima from sar ----------
SAR_OK=false; SAR_INT=0
if [ -s "$B/10-sar.txt" ] && ! grep -q "not installed" "$B/10-sar.txt"; then
  SAR_OK=true
  awk '
    BEGIN { split("ldavg-1 runq-sz blocked %iowait %steal %memused %commit pswpout/s majflt/s await %util", want, " ")
            for (i in want) W[want[i]] = 1 }
    /^Linux/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ || $i ~ /^[0-9][0-9]\/[0-9][0-9]\/[0-9]+$/) day = $i; next }
    $1 !~ /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/ { next }
    {
      hdr = 0
      for (i = 2; i <= NF; i++) if ($i in W) hdr = 1
      if (hdr) { delete col; devc = 0; for (i = 2; i <= NF; i++) { if ($i in W) col[$i] = i; if ($i == "DEV" || $i == "IFACE") devc = i } next }
      if ($2 ~ /^[A-Za-z%]/ && $2 != "all" && devc == 0) next
      # sampling interval from consecutive rows
      split($1, t, ":"); s = t[1]*3600 + t[2]*60 + t[3]
      if (prev != "" && s > prev && (iv == 0 || s - prev < iv)) iv = s - prev; prev = s
      for (m in col) { v = $(col[m]) + 0
        if (!(m in mx) || v > mx[m]) { mx[m] = v; at[m] = day " " $1; dv[m] = devc ? $(devc) : "" } }
    }
    END { for (m in mx) printf "SAR\t%s\t%s\t%s\t%s\n", m, mx[m], at[m], dv[m]; printf "IV\t%d\n", iv }
  ' "$B/10-sar.txt" > "$STATS.sar"
  SAR_INT=$(awk -F'\t' '$1=="IV"{print $2}' "$STATS.sar")
fi
sarmax() { awk -F'\t' -v m="$1" '$1=="SAR" && $2==m {print $3}' "$STATS.sar" 2>/dev/null; }
sarat() { awk -F'\t' -v m="$1" '$1=="SAR" && $2==m {print $4}' "$STATS.sar" 2>/dev/null; }

# ---------- observability ----------
KDUMP_LOADED=$(awk '/kexec_crash_loaded/{getline; print; exit}' "$B/13-kdump.txt")
CRASHK=$(grep -c "^crashkernel=" "$B/13-kdump.txt")
JPERSIST=$(grep -ho "journal storage: [a-z]*" "$B"/04-journal-*.txt 2>/dev/null | awk '{print $3}' | head -1)
TSYNC=$(grep -hE "System clock synchronized: yes|Leap status *: Normal" "$B/01-system.txt" | head -1)
VMCORES=$(section "ls -laR /var/crash" "$B/13-kdump.txt" | grep -c "vmcore")

# =================== CHECKS ===================
# --- stability events in the window ---
c=$(evc kernel_crash); [ "$c" -gt 0 ] && r=fail || r=pass
check STAB-01 critical stability $r "No kernel panic / BUG / Oops" "$c events (last $(evlast kernel_crash))" "0" "00-signals.txt" "Get the call trace; enable kdump if not already."
[ "$UNCLEAN" -gt 0 ] && r=fail || r=pass
check STAB-02 critical stability $r "Previous boots ended with a clean shutdown" "$UNCLEAN unclean of $((BOOTS-1 > 0 ? BOOTS-1 : 0)) previous boots" "0 unclean" "02-boots.txt" "Unclean end = crash, power loss, hypervisor or hardware watchdog reset."
c=$(evc oom); [ "$c" -gt 0 ] && r=fail || r=pass
check STAB-03 high stability $r "No OOM-killer activity" "$c processes killed (last $(evlast oom))" "0" "00-signals.txt, 06-memory.txt" "Check whether CONSTRAINT_MEMCG (service limit) or global OOM."
c=$(evc hung_task); [ "$c" -gt 0 ] && r=fail || r=pass
check STAB-04 high stability $r "No hung tasks (blocked > 120 s)" "$c (last $(evlast hung_task))" "0" "00-signals.txt" "Usually storage / NFS latency; read the blocked task stack."
c=$(evc cpu_stall); [ "$c" -gt 0 ] && r=fail || r=pass
check STAB-05 high stability $r "No soft lockups / RCU stalls" "$c (last $(evlast cpu_stall))" "0" "00-signals.txt" "On VMs check CPU steal / host overcommit."
c=$(evc service_failure); f=$(awk -F'\t' '{s+=$3} END{print s+0}' "$STATS.svc"); rr=$(awk -F'\t' '{s+=$4} END{print s+0}' "$STATS.svc")
if [ "$f" -gt 0 ] || [ "$FAILED_UNITS" -gt 0 ]; then r=fail; elif [ "$c" -gt 0 ]; then r=warn; else r=pass; fi
check STAB-06 high services $r "Services not crashing or restart-looping" "$FAILED_UNITS failed units now; $f unit failures, $rr automatic restarts in window; $c failure log lines" "0" "12-services.txt" "See the per-unit table in statistics."
EXP_PORTS=$(sed -n 's/^expected_ports=//p' "$B/MANIFEST.txt")
if [ -n "$EXP_PORTS" ]; then
  LISTEN=$(section "ss -ltnup" "$B/09-network.txt")
  MISSING=$(for p in $(echo "$EXP_PORTS" | tr ',' ' '); do echo "$LISTEN" | grep -qE "[:.]$p[[:space:]]" || printf '%s ' "$p"; done)
  [ -n "$MISSING" ] && r=fail || r=pass
  check SVC-01 critical services $r "Expected service ports are listening at collection time" "$([ -n "$MISSING" ] && echo "not listening: $MISSING" || echo "all listening: $EXP_PORTS")" "listening: $EXP_PORTS" "09-network.txt" "Given with collect.sh -l. A port down now means the outage may be ongoing."
else
  check SVC-01 critical services notchecked "Expected service ports are listening at collection time" "no ports given" "pass collect.sh -l PORTS" "09-network.txt"
fi
[ "$COREDUMPS" -gt 0 ] && r=warn || r=pass
check STAB-07 medium services $r "No application core dumps" "$COREDUMPS" "0" "12-services.txt"

# --- hardware / platform ---
c=$(evc hardware); [ "$c" -gt 0 ] && r=fail || r=pass
check HW-01 critical hardware $r "No machine-check / EDAC / hardware errors" "$c" "0" "00-signals.txt" "Escalate to hardware vendor / hypervisor team."
c=$(evc io_error); [ "$c" -gt 0 ] && r=fail || r=pass
check HW-02 critical storage $r "No block-device I/O errors" "$c (last $(evlast io_error))" "0" "00-signals.txt, 08-storage.txt"
[ "$TAINT" != 0 ] && r=warn || r=pass
check HW-03 low kernel $r "Kernel not tainted" "tainted=$TAINT" "0" "01-system.txt" "Non-zero: proprietary/out-of-tree module or prior warning; affects vendor support."
if $SAR_OK; then st=$(sarmax %steal); st=${st:-0}
  if fgt "$st" 20; then r=fail; elif fgt "$st" 5; then r=warn; else r=pass; fi
  check HW-04 high virtualization $r "CPU steal time low (hypervisor contention)" "max ${st}% at $(sarat %steal)" "< 5%" "10-sar.txt"
fi

# --- storage ---
c=$(evc filesystem); [ "$c" -gt 0 ] && r=fail || r=pass
check STO-01 critical storage $r "No filesystem errors / read-only remounts" "$c events; $RO_MOUNTS read-only mounts now" "0" "00-signals.txt, 08-storage.txt"
if [ "$DF_MAX" -ge 95 ]; then r=fail; elif [ "$DF_MAX" -ge 85 ]; then r=warn; else r=pass; fi
check STO-02 high storage $r "Filesystem space usage below 85%" "max ${DF_MAX}% on ${DF_MNT:-n/a}" "< 85%" "08-storage.txt"
if [ "$DI_MAX" -ge 95 ]; then r=fail; elif [ "$DI_MAX" -ge 85 ]; then r=warn; else r=pass; fi
check STO-03 high storage $r "Inode usage below 85%" "max ${DI_MAX}% on ${DI_MNT:-n/a}" "< 85%" "08-storage.txt"
c=$(evc nfs); [ "$c" -gt 0 ] && r=fail || r=pass
check STO-04 high storage $r "No NFS server-not-responding events" "$c" "0" "00-signals.txt"
if $SAR_OK; then aw=$(sarmax await); aw=${aw:-0}
  if fgt "$aw" 200; then r=fail; elif fgt "$aw" 50; then r=warn; else r=pass; fi
  check STO-05 medium storage $r "Disk latency (await) acceptable" "max ${aw} ms at $(sarat await)" "< 50 ms" "10-sar.txt"
  io=$(sarmax %iowait); io=${io:-0}
  if fgt "$io" 30; then r=fail; elif fgt "$io" 10; then r=warn; else r=pass; fi
  check STO-06 medium storage $r "CPU iowait acceptable" "max ${io}% at $(sarat %iowait)" "< 10%" "10-sar.txt"
fi

# --- memory ---
if fgt 5 "$MEMA_PCT"; then r=fail; elif fgt 10 "$MEMA_PCT"; then r=warn; else r=pass; fi
check MEM-01 high memory $r "Available memory above 10%" "${MEMA_PCT}% available ($((MEMA/1024)) MiB)" "> 10%" "06-memory.txt"
if [ "$SWT" -eq 0 ]; then r=notchecked; elif fgt "$SWU_PCT" 80; then r=fail; elif fgt "$SWU_PCT" 50; then r=warn; else r=pass; fi
check MEM-02 medium memory $r "Swap usage below 50%" "${SWU_PCT}% of $((SWT/1024)) MiB" "< 50%" "06-memory.txt" "Swap can hide a leak until a limit (MemorySwapMax, no swap) removes the cushion."
if fgt "$PSI_MEM" 5; then r=fail; elif fgt "$PSI_MEM" 1; then r=warn; else r=pass; fi
check MEM-03 medium memory $r "Memory pressure (PSI full avg300) low" "$PSI_MEM" "< 1" "06-memory.txt"
if $SAR_OK; then mu=$(sarmax %memused); sw=$(sarmax pswpout/s); mf=$(sarmax majflt/s)
  if fgt "${sw:-0}" 1000; then r=fail; elif fgt "${sw:-0}" 100; then r=warn; else r=pass; fi
  check MEM-04 medium memory $r "No swap storms in history" "max pswpout/s ${sw:-0} at $(sarat pswpout/s); max %memused ${mu:-0}; max majflt/s ${mf:-0}" "pswpout/s < 100" "10-sar.txt"
fi

# --- cpu / limits ---
if fgt "${LOAD15:-0}" $((NCPU*2)); then r=fail; elif fgt "${LOAD15:-0}" "$NCPU"; then r=warn; else r=pass; fi
check CPU-01 medium cpu $r "Load average (15 min) within CPU count" "load ${LOADLINE%% [0-9]*/*} on $NCPU CPUs" "< $NCPU" "07-cpu-procs.txt"
if $SAR_OK; then ld=$(sarmax ldavg-1)
  if fgt "${ld:-0}" $((NCPU*4)); then r=fail; elif fgt "${ld:-0}" $((NCPU*2)); then r=warn; else r=pass; fi
  check CPU-02 medium cpu $r "No load spikes in history" "max ldavg-1 ${ld:-0} at $(sarat ldavg-1); max blocked $(sarmax blocked)" "< $((NCPU*2))" "10-sar.txt"
fi
[ "$DSTATE" -gt 0 ] && r=warn || r=pass
check CPU-03 medium cpu $r "No processes stuck in D state now" "$DSTATE" "0" "07-cpu-procs.txt"
if fgt "$FD_PCT" 90; then r=fail; elif fgt "$FD_PCT" 70; then r=warn; else r=pass; fi
c=$(evc resource_limit); [ "$c" -gt 0 ] && r=fail
check LIM-01 high limits $r "File descriptors / allocation limits not exhausted" "fd ${FD_PCT}% used; $c 'too many open files' / allocation-failure events" "< 70%, 0 events" "07-cpu-procs.txt, 00-signals.txt"

# --- network ---
if fgt "$CT_PCT" 90; then r=fail; elif fgt "$CT_PCT" 70; then r=warn; else r=pass; fi
c=$(evc network); [ "$c" -gt 0 ] && [ "$r" = pass ] && r=warn
check NET-01 high network $r "Network stack healthy (conntrack, link, SYN flood)" "conntrack ${CT_PCT}%; $c network events (last $(evlast network))" "< 70%, 0 events" "09-network.txt, 00-signals.txt"
[ "$NIC_ERR" -gt 0 ] && r=warn || r=pass
check NET-02 medium network $r "No NIC error/drop counters" "$NIC_ERR non-zero error counters" "0" "09-network.txt"
[ "$SOFTNET_DROPS" -gt 0 ] && r=warn || r=pass
check NET-03 low network $r "No softnet backlog drops" "$SOFTNET_DROPS" "0" "09-network.txt"
[ "$LISTEN_OVF" -gt 0 ] && r=warn || r=pass
check NET-04 low network $r "No listen-queue overflows (since boot)" "ListenOverflows=$LISTEN_OVF ListenDrops=$LISTEN_DROP" "0" "09-network.txt" "Cumulative since boot; correlate with outage times before blaming."

# --- observability (can we diagnose the next one?) ---
$SAR_OK && r=pass || r=fail
check OBS-01 high observability $r "Historical performance data (sysstat) available" "$($SAR_OK && echo "yes, interval ${SAR_INT}s" || echo no)" "yes" "10-sar.txt" "Install/enable sysstat; 1-minute interval for intermittent issues."
if $SAR_OK && [ "${SAR_INT:-0}" -gt 300 ]; then r=warn; elif $SAR_OK; then r=pass; else r=notchecked; fi
check OBS-02 low observability $r "sar sampling interval short enough for short outages" "${SAR_INT}s" "<= 300 s (60 s ideal)" "10-sar.txt"
if [ "$KDUMP_LOADED" = 1 ]; then r=pass; elif [ "$CRASHK" -gt 0 ]; then r=warn; else r=fail; fi
check OBS-03 medium observability $r "kdump ready to capture a kernel crash" "crash kernel loaded=${KDUMP_LOADED:-?}; crashkernel= on cmdline: $CRASHK; vmcores present: $VMCORES" "loaded=1" "13-kdump.txt"
case $JPERSIST in persistent) r=pass ;; volatile) r=fail ;; *) r=notchecked ;; esac
check OBS-04 medium observability $r "Journal is persistent across reboots" "${JPERSIST:-unknown}" "persistent" "04-journal-disk-usage.txt" "Without it, logs from before a crash are lost."
[ -n "$TSYNC" ] && r=pass || r=warn
check OBS-05 low observability $r "Clock synchronised (needed to correlate events)" "$([ -n "$TSYNC" ] && echo synchronized || echo 'not confirmed')" "synchronized" "01-system.txt"

# =================== XML ===================
TOTAL=$((NP+NW+NF)); SCORE=$(pct "$NP" "$TOTAL")
if [ "$NF" -gt 0 ] && grep -q 'severity="critical" category="[a-z]*" result="fail"' "$CHECKS"; then STATUS=critical
elif [ "$NF" -gt 0 ]; then STATUS=degraded; elif [ "$NW" -gt 0 ]; then STATUS=attention; else STATUS=healthy; fi

{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo '<?xml-stylesheet type="text/xsl" href="phase1.xsl"?>'
  printf '<rca-phase1-report version="%s" generated="%s" redacted="%s">\n' "$VERSION" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$REDACTED"
  echo '  <system>'
  printf '    <host>%s</host>\n    <os>%s</os>\n    <kernel>%s</kernel>\n' "$(e "$HOST")" "$(e "$OS")" "$(e "$KERNEL")"
  printf '    <virtualization>%s</virtualization>\n    <cpus>%s</cpus>\n    <memory-mib>%s</memory-mib>\n' "$(e "${VIRT:-unknown}")" "$NCPU" "$((MEMT/1024))"
  printf '    <uptime>%s</uptime>\n' "$(e "$(echo "$UPTIME" | sed 's/^ *//')")"
  printf '    <collected>%s</collected>\n    <window since="%s" days="%s"/>\n' "$(e "$COLLECTED")" "$(e "$SINCE")" "$(e "$DAYS")"
  echo '  </system>'
  printf '  <summary status="%s" score="%s" pass="%d" warn="%d" fail="%d" notchecked="%d"/>\n' "$STATUS" "$SCORE" "$NP" "$NW" "$NF" "$NN"
  echo '  <statistics>'
  echo '    <events source="journal (window) + dmesg ring buffer">'
  awk -F'\t' "$XA"'$1=="EV"{printf "      <event category=\"%s\" count=\"%s\" first=\"%s\" last=\"%s\"/>\n", $2, $3, xa($4), xa($5)}' "$STATS.ev"
  echo '    </events>'
  echo '    <oom-victims>'
  awk -F'\t' "$XA"'$1=="OOMV"{printf "      <process name=\"%s\" kills=\"%s\"/>\n", xa($2), $3}' "$STATS.ev"
  echo '    </oom-victims>'
  echo '    <services>'
  awk -F'\t' "$XA"'{printf "      <unit name=\"%s\" failures=\"%s\" restarts=\"%s\" last-result=\"%s\"/>\n", xa($2), $3, $4, xa($5)}' "$STATS.svc"
  echo '    </services>'
  printf '    <boots total="%s" unclean="%s"/>\n' "$BOOTS" "$UNCLEAN"
  echo '    <resources>'
  printf '      <metric name="mem_available_pct" value="%s"/>\n      <metric name="swap_used_pct" value="%s"/>\n' "$MEMA_PCT" "$SWU_PCT"
  printf '      <metric name="psi_memory_full_avg300" value="%s"/>\n      <metric name="psi_io_full_avg300" value="%s"/>\n      <metric name="psi_cpu_some_avg300" value="%s"/>\n' "$PSI_MEM" "$PSI_IO" "$PSI_CPU"
  printf '      <metric name="load_1_5_15" value="%s"/>\n      <metric name="d_state_tasks" value="%s"/>\n' "$(e "$(echo "$LOADLINE" | cut -d' ' -f1-3)")" "$DSTATE"
  printf '      <metric name="fd_used_pct" value="%s"/>\n      <metric name="conntrack_used_pct" value="%s"/>\n' "$FD_PCT" "$CT_PCT"
  printf '      <metric name="softnet_drops" value="%s"/>\n      <metric name="listen_overflows" value="%s"/>\n' "$SOFTNET_DROPS" "$LISTEN_OVF"
  awk -F'\t' "$XA"'{printf "      <filesystem mount=\"%s\" used-pct=\"%s\"/>\n", xa($2), $1}' "$STATS.df"
  echo '    </resources>'
  if $SAR_OK; then
    printf '    <history source="sar" interval-seconds="%s">\n' "$SAR_INT"
    awk -F'\t' "$XA"'$1=="SAR"{printf "      <peak metric=\"%s\" max=\"%s\" at=\"%s\" device=\"%s\"/>\n", xa($2), $3, xa($4), xa($5)}' "$STATS.sar" | sort
    echo '    </history>'
  fi
  echo '  </statistics>'
  echo '  <checks>'
  cat "$CHECKS"
  echo '  </checks>'
  echo '</rca-phase1-report>'
} > "$XML"
rm -f "$STATS".*
echo "phase 1 report: $XML  [status=$STATUS score=$SCORE% pass=$NP warn=$NW fail=$NF]"
