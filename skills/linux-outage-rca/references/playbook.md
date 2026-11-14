# Intermittent outage triage playbook

Work from evidence to hypothesis, never the reverse. For every claim in the RCA, cite the file + line
(e.g. `00-signals.txt: 2026-11-10T03:12:44 ... invoked oom-killer`).

## Step 0 — Pin down what "unavailable" means

Ask (or infer from data) before analysing:

| Question | Why it matters |
|---|---|
| Exact outage timestamps (+ timezone) from the client's monitoring | Everything is correlated against these |
| Did the host **reboot**, **hang** (no ping/SSH, no reboot), or was only the **app** down? | Splits the tree below |
| Ping works but SSH doesn't? | Points to userspace/memory/fork exhaustion, not network |
| Recovery: by itself, by app restart, by hard reset? | Self-recovery = resource pressure; hard reset = hang/panic |
| Bare metal / VMware / KVM / cloud? Any changes (patch, deploy, traffic) before it started? | Steal time, ballooning, host-side issues; regression window |
| Is it periodic (same time daily)? | Cron, backup, logrotate, snapshot, AV scan |

## Step 1 — Read in this order

1. `MANIFEST.txt` — what tools exist, was it root.
2. `02-boots.txt` — boot list vs outage times. A boot whose last lines are **not** a clean shutdown
   (`Reached target Power-Off`, `systemd-shutdown`) = crash / hard reset / watchdog.
3. `00-signals.txt` — counts first; then hits near outage timestamps.
4. `10-sar.txt` — the minutes before each outage: `-q` (runq/load/blocked), `-r` (%memused, kbcommit),
   `-W` (swap in/out), `-B` (majflt, pgscand), `-d` (await, %util), `-n EDEV`.
5. Then the domain file the signals point to.

Timestamps: `dmesg -T` converts from monotonic time and drifts (minutes on long-running VMs, wrong after
suspend). Use journal/syslog wall-clock times for the timeline; only use `dmesg -T` when nothing else exists.
Swap can hide a memory leak for a long time — a service that only got slow, then started dying after a change,
often had a swap limit (`MemorySwapMax=0`) or swap removed.

## Step 2 — Decision tree

### A. Host rebooted unexpectedly
- `Kernel panic` / `BUG:` / `Oops` in previous boot or `/var/crash/*/vmcore-dmesg.txt` → kernel crash.
  Get the call trace, the module at top of stack, tainted flags (`01-system.txt`). Match against vendor KB /
  kernel changelog for the running version. If kdump not configured → recommendation #1 is enable it.
- Previous boot just **stops** mid-log, no panic → power loss, hypervisor reset, hardware watchdog (iLO/iDRAC
  ASR), or panic that couldn't be written. Check: IPMI SEL (`ipmitool sel elist`, ask client), hypervisor
  events, `mce:` / `EDAC` / `Hardware Error`.
- `softlockup_panic=1`, `panic_on_oops=1`, `hung_task_panic=1` in `07-cpu-procs.txt`/sysctl turn stalls into reboots.

### B. Host hung (no reboot, needed hard reset or recovered after minutes)
- `blocked for more than 120 seconds` (hung_task) → identify the stack: in `xfs_*`/`ext4_*`/`jbd2`/`blk_*`
  → storage latency or failing path (check `08-storage.txt`, multipath, `I/O error`, `task abort`,
  sar `-d` await spikes). In `nfs_*`/`rpc_*` → NFS server unreachable (hard mounts block forever).
- `soft lockup` / `rcu ... stall` → CPU stuck in kernel. On VMs very often **host overcommit**: check
  `%steal` in sar `-u`, `clocksource unstable`, balloon driver messages.
- Memory thrash without OOM: sar `-B` high `majflt/s` + `pgscand/s`, `-W` swap storms, PSI memory `full`
  high, `kbcommit` > RAM+swap. System is "up" but unusable. Classic: swap on slow disk + leaking app.
- Fork/fd exhaustion: `Too many open files`, `fork: retry`, `nprocs` near `pid_max`/`threads-max`,
  `file-nr` near `file-max`.

### C. Only the service/app was down
- `Killed process ... (java|mysqld|...)` → OOM killer. Read the OOM report: total RSS per process,
  `oom_score_adj`, which cgroup (`memory.events` in `06-memory.txt`). Distinguish **cgroup/container limit**
  (constraint=CONSTRAINT_MEMCG) from **global OOM**.
- `Main process exited` / `Scheduled restart job` in `12-services.txt` → app crash; check `coredumpctl`.
- Network-only symptoms: `nf_conntrack: table full`, `possible SYN flooding`, `TCP: out of memory`,
  NIC `tx timeout`/`Link is Down`, bond failover, rx drops in `ethtool -S`/`softnet_stat` (2nd column =
  drops, 3rd = time_squeeze), `ListenOverflows`/`ListenDrops` in `nstat`.
- Disk full / inode full / filesystem remounted read-only (`08-storage.txt`).

### D. Nothing in the logs
- Logs gap during the outage = journald couldn't write (disk/IO hang) — that itself is evidence.
- No sar → can't see history; deploy `watch.sh` (with approval) and enable sysstat, wait for next event.
- Consider external causes: upstream LB health checks, DNS, firewall/IPS, backup snapshots (VM stun),
  NTP step causing app timeouts.

## Step 3 — Confirm

A root cause is **confirmed** only if: (1) it is present at every outage timestamp, (2) its mechanism
explains the observed symptom, and (3) ideally it can be reproduced or the fix makes it stop. Otherwise
label it **probable** and say what evidence would confirm it.

## Step 4 — Fix with minimal disruption

Always propose, never apply unasked. Each change: exact command, risk, rollback, whether it needs a reboot.
Prefer runtime-reversible changes first (sysctl -w, systemd drop-in) then persist.

Common fixes:
- OOM / leak: set `MemoryMax=` / JVM `-Xmx` sized to the box, fix leaking component, add swap only as buffer,
  `vm.min_free_kbytes` sanity, `oom_score_adj` to protect sshd.
- Hung tasks on storage: fix path/multipath (`no_path_retry`, `queue_if_no_path` hangs forever), firmware,
  `nfs` → `soft,timeo,retrans` or automount, I/O scheduler.
- VM stalls: raise with hypervisor team (CPU ready/steal, ballooning, snapshot consolidation).
- conntrack: raise `nf_conntrack_max` + hashsize, or NOTRACK for high-volume flows.
- Observability so it never goes blind again: sysstat at 1-min interval, kdump with `crashkernel=`,
  persistent journal (`Storage=persistent`), `kernel.hung_task_warnings`, remote syslog, node_exporter.

## Tooling cheatsheet (when live access is allowed)

- `perf top -g`, `perf record -ag -- sleep 30` — CPU hot paths (needs approval; overhead small).
- `strace -fp PID -tt -T -c` — syscall stalls of a stuck app (overhead high on busy procs — approval).
- `tcpdump -i IF -s 128 -w /var/tmp/x.pcap 'port N' -c 100000` — bounded capture (approval; may hold PII).
- `crash /usr/lib/debug/.../vmlinux /var/crash/.../vmcore` → `bt`, `log`, `ps | grep UN`, `kmem -i`.
- `echo w > /proc/sysrq-trigger` dumps blocked tasks to dmesg — safe but write op, ask first.
