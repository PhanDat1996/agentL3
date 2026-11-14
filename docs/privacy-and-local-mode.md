# Privacy options: redaction and fully local analysis

Clients often can't send server logs to a third-party AI. Pick the lightest option that satisfies their policy:

| Option | Where the evidence goes | Analysis quality |
|---|---|---|
| A. Claude via the client's own Bedrock / Vertex account | Stays in the client's cloud tenant | Same as default |
| B. Redacted bundle (`collect.sh -r`) | Leaves the host with identifiers tokenised | Same as default |
| C. Local model (`local/claude-local.sh`) | Never leaves the analysis machine | Lower; depends on model and hardware |
| B + C | Both | Lower |
| D. No AI on client data | Engineer analyses with the playbook; agent only drafts the report from the engineer's notes | Engineer-dependent |

## B. Redaction

```bash
sudo bash collect.sh -d 14 -r                       # standard identifiers
sudo bash collect.sh -d 14 -x terms.txt             # + extra terms (implies -r)
```

`terms.txt` holds one term per line: customer name, app names, internal project codenames, anything else
identifying.

What is replaced, consistently across all files (the same IP gets the same token everywhere):

| Value | Token |
|---|---|
| Hostname (short + FQDN), DNS domain, resolv.conf search domains | `HOST_n`, `DOMAIN_n` |
| Local users (UID 1000–65533) | `USER_n` |
| IPv4 (private vs public kept apart), global IPv6 | `IP_PRIV_n`, `IP_PUB_n`, `IP6_n` |
| MAC addresses, e-mail addresses, SSH key fingerprints | `MAC_n`, `EMAIL_n`, `FP_n` |
| Extra terms from `-x` | `TERM_n` |

Kept for readability: `127.x`, `0.0.0.0`, broadcast, systemd unit names like `user@1000.service`, package
versions, timestamps.

The map (`/tmp/rca-redact-map-<ts>.txt`, mode 600) stays on the host. The client can translate the tokens in
the RCA back to real names, or send you only the few entries you need. Redaction is best-effort pattern
matching: the client should spot-check the bundle before sending (`grep -ri <name> rca-redacted-*/`).

## C. Fully local (Ollama)

Claude Code talks to Ollama ≥ 0.14 through its Anthropic-compatible API, so the same agent and skill run
unchanged on an open-weight model.

```bash
ollama pull qwen3-coder:30b            # once, while online
./install.sh                           # agent + skill into ~/.claude
./local/claude-local.sh qwen3-coder:30b 65536
```

The launcher:
- creates a derived model with a large context window (`num_ctx`). Ollama's default context is small, and
  log analysis needs a large one: otherwise the start of the bundle is silently dropped;
- routes every model slot (main, subagents, fast tasks) to the local model;
- sets `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` (no telemetry, error reports or update checks).

For an air-gapped analysis box: pull the model and install Claude Code while online, then disconnect.

### Sizing guide

| RAM / VRAM | Suggested model | Context |
|---|---|---|
| 16 GB | `gpt-oss:20b` | 32k |
| 32–48 GB | `qwen3-coder:30b` | 64k |
| 64 GB+ | larger coder/reasoning models | 128k |

Test any model on `examples/` before using it on a client case: tool calling and long-context behaviour
vary a lot between models.

### What to expect from a local model

Open-weight models are weaker at correlating timestamps across many files and at not over-claiming. The
skill compensates:
- `00-signals.txt` is a pre-filtered summary, so the model doesn't need to read whole logs;
- the playbook's read order keeps the context small;
- the "confirmed vs probable" rule and evidence citations make weak conclusions easy to spot.

Treat the local model's RCA as a draft: verify every cited line yourself before it goes to the client.
