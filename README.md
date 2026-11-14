# agentL3 — Linux L3 outage RCA agent for Claude Code

A Claude Code subagent + skill that works like a senior Linux L3 support engineer on someone else's
production server: collects evidence **read-only**, correlates it against the outage timestamps, finds the
root cause, proposes fixes with risk and rollback, and writes a client-ready RCA report.

Built for the "intermittent server outage — find the root cause and write an RCA" kind of engagement on
RHEL / CentOS / Rocky / Alma / Ubuntu / Debian.

## What's inside

```
agents/linux-l3-rca.md                     subagent definition (preloads the skill)
skills/linux-outage-rca/
  SKILL.md                                 workflow + safety rules
  scripts/collect.sh                       read-only evidence bundle (~20 s, time-boxed commands)
  scripts/watch.sh                         opt-in flight recorder to catch the next occurrence
  references/playbook.md                   triage questions, read order, decision tree, common fixes
  templates/rca-report.md                  RCA deliverable format
examples/
  lab-fault/                               the fault used to test the agent blind
  RCA-example-inventory-api.md             the report the agent produced
```

## Install

```bash
git clone https://github.com/PhanDat1996/agentL3.git
cd agentL3 && ./install.sh
```

This copies the agent to `~/.claude/agents/` and the skill to `~/.claude/skills/`. Restart Claude Code.

## Use

In Claude Code:

> Use the linux-l3-rca agent to investigate user@host. The API on port 8088 was down 07:04–07:05 and
> 07:10–07:11 UTC today and came back by itself.

Or hand it a bundle the client produced themselves:

```bash
sudo bash collect.sh -d 14 -s 30      # on the server; produces /tmp/rca-<host>-<ts>.tar.gz
```

> Analyse ./rca-web01-20261114-071313.tar.gz and write an RCA.

## Safety model

- Everything the agent runs on the target is read-only by default (`collect.sh` installs nothing and changes
  nothing; every command has a timeout so a hung NFS mount can't wedge it).
- Any change — `watch.sh start`, sysctl, restarts, config edits, perf/strace/tcpdump — needs explicit
  approval for that specific change, with the exact command, risk and rollback stated first.
- When running as a subagent it returns proposed changes instead of applying them.
- Every claim in the RCA cites a file, line and timestamp; causes are labelled confirmed vs probable.

## `collect.sh` coverage

Boot history and how each previous boot ended · kernel log and a signature scan (OOM, hung task, soft
lockup, panic, MCE/EDAC, I/O errors, read-only remounts, conntrack full, NIC tx timeout/link down, NFS not
responding, fd exhaustion, service crash loops) · memory + PSI + cgroup memory events · D-state tasks ·
storage, LVM, multipath, md, SMART · network counters, softnet drops, conntrack, bonding · `sar` history
for N days · live vmstat/iostat/mpstat sample · systemd failures, coredumps · kdump readiness · sysctl,
limits, recently installed packages · login history.

```
sudo bash collect.sh [-d DAYS] [-o OUTDIR] [-s SAMPLE_SECS]
```

## Blind test

`examples/lab-fault/` is a deliberately broken service: an unbounded in-memory cache on `/report`, a cron
job hitting it every 2 minutes, `MemoryMax=320M` with `MemorySwapMax=0`, and `RestartSec=45`. A red
herring cron job writes 400 MB with direct I/O every 5 minutes. The agent was given only what a client
would say (host, port, two outage windows) and:

- found the memcg OOM kill → 45 s restart cycle and the leaking code path,
- ruled out the I/O red herring with sar numbers, and unrelated old noise in the logs,
- noticed the unit file had been changed just before the outages started (swap limit removed the cushion),
- predicted the next kill time and watched it happen,
- left nothing on the host.

Report: [examples/RCA-example-inventory-api.md](examples/RCA-example-inventory-api.md).

## Requirements

Claude Code. On targets: bash, coreutils `timeout`; `sysstat` strongly recommended (without `sar` there's no
history — the playbook covers enabling it).
