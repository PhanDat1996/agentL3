# Root Cause Analysis — Inventory API (damon / lab-vm) intermittent outage

| | |
|---|---|
| Client / environment | Inventory API, HTTP :8088, `/health`; production |
| Hosts in scope | `damon` (lab-vm), Ubuntu 26.04 LTS, kernel 7.0.0-42-generic, Xen HVM domU VM, 4 vCPU, 7.2 GiB RAM, 4 GiB swap |
| Incident window | 2026-11-14 07:04:03–07:04:48 UTC and 07:10:03–07:10:48 UTC (client monitor, 5 s checks) |
| Prepared by / date | L3 support, 2026-11-14 |
| Status | **Root cause confirmed** (present at both incidents; mechanism verified in source and kernel logs; recurrence predicted and observed — see §5). Fix not yet applied (pending approval). |

## 1. Executive summary
The server did not crash or reboot. The Inventory API process was killed by the Linux kernel because it
ran out of the memory allowance (320 MiB) configured for the service. The API has a memory leak: every call to its
`/report` endpoint keeps 110 MiB in memory permanently, and a scheduled job calls `/report` every 2 minutes.
On the third call after each start the service goes over its limit, is killed, and systemd waits 45 seconds
before starting it again. That 45-second restart delay is exactly the outage the monitor saw. The pattern started
at 06:58 UTC today, when the service configuration was edited so that it could no longer spill the leaked memory
to swap. Until the leak is fixed, the outage will recur **about every 6 minutes** for ~45 s.

## 2. Impact and timeline (UTC, 2026-11-14)
| Time | Event | Source |
|---|---|---|
| 06:41:46–47 | `app.py`, `/etc/cron.d/inventory` and `inventory-api.service` deployed; service started | `stat` (live); `files/var/log/syslog` L6547–6551 |
| 06:42:01 → | cron `*/2` calls `curl http://127.0.0.1:8088/report` | `files/var/log/syslog` L6553+ |
| 06:50 / 07:00 | Leaked memory pushed to swap: `pswpout/s` 62.0 and 224.9 (normally 0) | `10-sar.txt` (sa14, `-W`) |
| 06:58:23.367 | Unit file `/etc/systemd/system/inventory-api.service` modified | `stat` mtime (live) |
| 06:58:23.389 | `systemctl daemon-reload` from an interactive session (session-1549), then service restart | `files/var/log/syslog` L6575–6584 |
| 06:58:23 | Old instance stopped: "320M memory peak, **684.3M memory swap peak**" | `files/var/log/syslog` L6583 |
| 07:00:01, 07:02:01 | `/report` calls #1, #2 (≈220 MiB held) | `files/var/log/syslog` L6587, L6591 |
| 07:04:01.479 | `/report` call #3 | `files/var/log/syslog` L6592 |
| 07:04:01.576 | Kernel memcg OOM: `memory: usage 327680kB, limit 327680kB`; `swap: usage 0kB, limit 0kB`; killed `python3` pid 262621 (anon-rss 326768 kB) | `files/var/log/syslog` L6627–6705; `00-signals.txt` |
| 07:04:01.618 | `inventory-api.service: Failed with result 'oom-kill'` | `12-services.txt` L73–74 |
| **07:04:03–07:04:48** | **API unreachable (client monitor)** | client |
| 07:04:46.73 | `Scheduled restart job, restart counter is at 1` → started (RestartSec=45) | `12-services.txt` L75; syslog L6711–6712 |
| 07:06:01, 07:08:01 | `/report` calls #1, #2 | syslog L6714–6715 |
| 07:10:01.788 | `/report` call #3 (dd scratch job also starts) | syslog L6720–6721 |
| 07:10:01.875 | memcg OOM, usage = limit 327680 kB; killed `python3` pid 262718 | syslog L6756–6834 |
| 07:10:01.914 | `Failed with result 'oom-kill'` | `12-services.txt` L76–77 |
| **07:10:03–07:10:48** | **API unreachable (client monitor)** | client |
| 07:10:46.98 | Restart counter 2 → started | `12-services.txt` L78 |
| 07:14:51 | Live: `MemoryCurrent=241041408` (≈230 MiB) after calls at 07:12 and 07:14 → next kill predicted at 07:16:01 | `systemctl show` (live) |
| 07:16:01 | **Predicted recurrence observed:** `/report` call → memcg OOM kill of pid 262875 (anon-rss 326788 kB) → `oom-kill`; restarted 07:16:47 (restart counter 3) | `evidence/live-journal-0716-recurrence.txt` |

## 3. Root cause
**Cause:** An unbounded in-memory cache in the `/report` handler of `/opt/inventory-api/app.py` grows by 110 MiB per
request; with `MemoryMax=320M` and `MemorySwapMax=0` the service's cgroup is OOM-killed on the third `/report`
call after every start.

**Mechanism:**
1. `/report` allocates `bytearray(110 * 1024 * 1024)`, touches every page, and appends it to the module-global
   list `_report_cache`, which is never trimmed (`app.py`, the `elif self.path.startswith("/report")` branch).
2. `/etc/cron.d/inventory` runs `curl -s -m 60 http://127.0.0.1:8088/report` every 2 minutes as root.
3. After 3 calls the process holds ~330 MiB anonymous memory > 320 MiB (`MemoryMax=320M` = 335544320 bytes).
   `MemorySwapMax=0` forbids swapping, so the kernel memcg OOM killer kills the only process in the cgroup
   (`constraint=CONSTRAINT_MEMCG, oom_memcg=/system.slice/inventory-api.service`).
4. systemd marks the unit failed (`oom-kill`), `Restart=on-failure` with `RestartSec=45` restarts it 45 s later.
   The port is closed during those 45 s → monitor sees 07:04:03–07:04:48 and 07:10:03–07:10:48 (kill +2 s to restart +2 s).
5. The new process starts with an empty cache, so the cycle repeats: 3 calls × 2 min = kill every ~6 minutes.

**Why intermittent:** The outage is a deterministic cycle (every 3rd `/report` call after a start ≈ every 6 min,
45 s down), which looks random from the outside. It began at 06:58:23 when the unit file was edited and the service
restarted. Before that edit the same leak was absorbed by swap (684.3 MiB swap peak, sar `pswpout` 62–225 pages/s),
so the service stayed up while it leaked. The current unit has `MemorySwapMax=0`; the earlier unit contents are not
in the evidence, so the exact edit is **probable** (adding `MemorySwapMax=0`) and should be confirmed against the change record.

### Supporting evidence
- Incident 1 — `files/var/log/syslog`:
  `07:04:01.479 CRON[262714]: (root) CMD (curl -s -m 60 http://127.0.0.1:8088/report ...)`
  `07:04:01.575 kernel: memory: usage 327680kB, limit 327680kB, failcnt 24` / `swap: usage 0kB, limit 0kB`
  `07:04:01.576 kernel: Memory cgroup out of memory: Killed process 262621 (python3) ... anon-rss:326768kB`
  `07:04:46.732 systemd[1]: inventory-api.service: Scheduled restart job, restart counter is at 1.`
- Incident 2 — same file:
  `07:10:01.787 CRON[262861]: (root) CMD (curl ... /report ...)`
  `07:10:01.875 kernel: memory: usage 327680kB, limit 327680kB, failcnt 26`
  `07:10:01.875 kernel: Memory cgroup out of memory: Killed process 262718 (python3) ... anon-rss:326780kB`
  `07:10:46.982 systemd[1]: ... restart counter is at 2.`
- Both killed instances report "320M memory peak" and ran 5 min 37 s / 6 min 0 s — i.e. exactly three 2-minute cron ticks.
- Unit (live `systemctl cat`): `MemoryMax=320M`, `MemorySwapMax=0`, `Restart=on-failure`, `RestartSec=45`, `DynamicUser=yes`.
- Note: `dmesg -T` shows these OOM events as 07:01:13 / 07:07:13; that is the known `dmesg -T` clock skew
  (~2 min 48 s). Journal/syslog timestamps are used throughout.

### Contributing factors
- Restart delay of 45 s turns every kill into a 45-second outage. With RestartSec of 1–2 s it would be a short blip.
- `MemorySwapMax=0` (changed 06:58:23) removed the swap buffer that had been hiding the leak.
- `/report` is described in the cron file as a "nightly-style export" but runs every 2 minutes.
- Monitoring checks only `/health` reachability. It does not alert on service restarts or memcg OOM events, so the
  cause was not visible to the client.
- Minor: `ThreadingHTTPServer` listen backlog is 5 (`ss`: `LISTEN 0 5 0.0.0.0:8088`), which will drop connections under load.

### Hypotheses ruled out
| Hypothesis | Evidence against |
|---|---|
| Host reboot / kernel panic / hang | One boot since 2026-10-28 08:41 (`02-boots.txt`); no panic, hung-task or soft-lockup signatures (`00-signals.txt`) |
| Hardware / hypervisor (Xen) | No MCE / hardware errors; the `EDAC` hit is driver init at boot; `%steal` 0.11–0.13% (`10-sar.txt` sa14 `-u`) |
| Host-wide memory exhaustion | `%memused` 3.9–7.9%, `kbavail` ≈6.5 GB at 06:50–07:10 (`10-sar.txt` `-r`); OOM is `CONSTRAINT_MEMCG`, not global |
| Disk I/O from the `*/5` dd scratch job (400 MB O_DIRECT) | `await` 1.2–3.1 ms, `%util` < 1% (`10-sar.txt` `-d`); dd ran at 07:00 with no outage, and did not run at 07:04 when the first outage happened |
| Network / conntrack / NIC | No NIC errors in `sar -n EDEV`; conntrack 24/262144 (`09-network.txt`); `ListenOverflows 1781` is cumulative since boot (SYN flood on 127.0.0.1:9100 on 2026-10-28) and not tied to these times |
| Filesystem errors | `EXT4-fs error (device loop0) trigger_test_error` on 2026-11-13 is a deliberately injected test on a loop device, unrelated |
| Other failing units | `labtimer-demo.service` failures at 04:21 / 04:28 are unrelated in time and cgroup |

## 4. Corrective actions (proposed — none applied; no changes were approved for this engagement)
| # | Change | Applied | Risk / downtime | Rollback |
|---|---|---|---|---|
| 1 | **Permanent fix (app owner):** remove or bound `_report_cache` in `/opt/inventory-api/app.py` (do not keep each 110 MiB report; stream or return it and drop the reference, or keep only the latest N entries / use an LRU with a byte cap). Deploy, then `sudo systemctl restart inventory-api`. | No | One restart (~1 s). Needs code review and a test of `/report` in staging. | Redeploy the previous `app.py` and restart. |
| 2 | **Immediate mitigation:** stop the 2-minute `/report` calls until #1 ships. Comment out the `*/2` line in `/etc/cron.d/inventory`, or set it to the intended nightly schedule (e.g. `0 2 * * *`). Cron re-reads `/etc/cron.d` on its own. | No | No downtime. The report is generated less often, so confirm with the business that this is acceptable. Even nightly, the leak stays until #1 ships. | Restore the original line. |
| 3 | **Shorten the outage per kill:** drop-in `sudo systemctl edit inventory-api` → `[Service]` `RestartSec=2s`, then `sudo systemctl daemon-reload` (takes effect on the next restart, no restart needed). | No | Low. A crash loop restarts faster but is still bounded by default `StartLimitBurst=5/10s`. | `sudo rm /etc/systemd/system/inventory-api.service.d/override.conf && sudo systemctl daemon-reload` |
| 4 | Do **not** "fix" by raising `MemoryMax` or allowing swap again: that only delays the kill (≈ +110 MiB per 2 min) and shifts the pressure to the whole host. Use it only as a short stop-gap with #2. | — | — | — |

Recommended order: #2 (now), #3 (now), #1 (as soon as the app team can ship). Each change on its own, verified before the next.

## 5. Validation
- Prediction from the evidence: with calls at 07:12 and 07:14 (`MemoryCurrent` ≈ 230 MiB at 07:14:51), the third call at
  07:16:01 should trigger the next OOM kill and a 45 s outage until ~07:16:46.
- Observation (read-only journal check at 07:17:09): **the prediction held.** `07:16:01 CRON ... /report` → `07:16:01 kernel: Memory cgroup out of memory: Killed process 262875 (python3) ... anon-rss:326788kB` → `Failed with result 'oom-kill'` → `07:16:47 Scheduled restart job, restart counter is at 3` (`evidence/live-journal-0716-recurrence.txt`). This confirms the mechanism and the 6-minute cycle. The client monitor should show a third gap at about 07:16:03–07:16:48; please compare. Expected next kills: 07:22:01, 07:28:01, … until the fix is in place.
- After fixes: `NRestarts` should stay constant, `journalctl -k | grep -c 'Memory cgroup out of memory'` should not grow, and
  `MemoryCurrent` should stay flat across several `/report` calls. Check over at least 1 hour (≥ 30 `/report` cycles if the cron stays on),
  and the client monitor should show no gaps.

## 6. Preventive recommendations
| Priority | Recommendation | Effort |
|---|---|---|
| High | Fix the leak (#1) and add a regression test that calls `/report` N times and asserts RSS stays bounded | Low–Medium |
| High | Alert on systemd unit restarts / `oom-kill` results and on kernel `Memory cgroup out of memory` (journal → syslog/monitoring), not just on `/health` | Low |
| Medium | Change control: today's unit edit at 06:58:23 (made from an interactive SSH session) changed behaviour with no record; require a ticket and before/after diff for unit/cron changes | Low |
| Medium | Set `MemoryHigh=` (e.g. 280M) under `MemoryMax` so pressure is visible (`memory.events high`) before the hard kill | Low |
| Low | Run the HTTP server behind a production-grade server (or raise `request_queue_size`) instead of a backlog of 5 | Low |
| Low | Raise sysstat interval to 1 min for finer correlation (currently 10 min) | Low |

## Appendix
- Evidence bundle: `evidence/rca-damon-20261114-071313.tar.gz` (extracted alongside); worklog `worklog-lab-vm.md`.
- Commands run on the system (all read-only; no changes made):
  - `scp collect.sh → /tmp/collect.sh`; `sudo bash /tmp/collect.sh -d 14 -s 30` (writes only to `/tmp/rca-damon-20261114-071313*`)
  - `sudo systemctl cat inventory-api.service`; `systemctl show inventory-api -p Memory*,Restart*,NRestarts,...`
  - `sudo cat /etc/cron.d/inventory`; `sudo cat /opt/inventory-api/app.py`; `ls -la /opt/inventory-api`; `stat` on unit/cron/app
  - `sudo journalctl -u inventory-api ...`; `sudo journalctl --since ...` (filtered); `ss -ltnp`; `free -m`
  - `curl -s -m 3 http://127.0.0.1:8088/health` (one GET to the health endpoint, which changes nothing)
- Cleanup: removed `/tmp/collect.sh`, `/tmp/rca-damon-20261114-071313/` and `/tmp/rca-damon-20261114-071313.tar.gz` from the host. `watch.sh` was not started.
