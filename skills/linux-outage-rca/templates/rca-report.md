# Root Cause Analysis — {{host / service}} intermittent outage

| | |
|---|---|
| Client / environment | {{}} |
| Hosts in scope | {{hostname, OS + kernel, bare metal/VM}} |
| Incident window | {{first seen → last seen, timezone}} |
| Prepared by / date | {{}} |
| Status | {{Root cause confirmed / Probable — pending validation}} |

## 1. Executive summary
{{3–5 sentences for a non-technical reader: what happened, why, what was done, current risk.}}

## 2. Impact and timeline
| Time (TZ) | Event | Source |
|---|---|---|
| {{}} | {{e.g. load avg 64, runq 120}} | `10-sar.txt` |
| {{}} | {{service unreachable (client monitoring)}} | client |

## 3. Root cause
**Cause:** {{one sentence}}
**Mechanism:** {{how it leads to the outage, step by step}}
**Why intermittent:** {{trigger condition — traffic peak, cron at 02:00, backup snapshot, leak over N days}}

### Supporting evidence
{{Log excerpts, sar rows, stack traces — each with file/source and timestamp. Show it at every incident.}}

### Contributing factors
- {{e.g. no memory limit on service, swap on slow disk, kdump not configured}}

### Hypotheses ruled out
| Hypothesis | Evidence against |
|---|---|
| {{Hardware fault}} | {{no MCE/EDAC, SMART clean}} |

## 4. Corrective actions
| # | Change | Applied (when/by) | Risk / downtime | Rollback |
|---|---|---|---|---|
| 1 | {{}} | {{}} | {{}} | {{}} |

## 5. Validation
{{What was measured after the fix and for how long; before/after numbers; the trigger condition reproduced
or observed again without impact.}}

## 6. Preventive recommendations
| Priority | Recommendation | Effort |
|---|---|---|
| High | {{}} | {{}} |

## Appendix
- Evidence bundle: {{rca-host-ts.tar.gz}}
- Commands run on the system (all read-only unless listed in §4): {{}}
