#!/usr/bin/env bash
# claude-local.sh — run Claude Code (and the linux-l3-rca agent) against a local
# Ollama model, so evidence never leaves this machine.
#
# Usage: ./local/claude-local.sh [MODEL] [CTX]      e.g. ./local/claude-local.sh qwen3-coder:30b 65536
#   MODEL  any Ollama model with tool calling (default qwen3-coder:30b)
#   CTX    context window in tokens (default 65536). Ollama's default is far too
#          small for log analysis: the model silently loses the start of the bundle.
#
# Needs Ollama >= 0.14 (Anthropic-compatible API) and Claude Code. The model must
# already be pulled — this script does not download anything.

set -euo pipefail
MODEL=${1:-qwen3-coder:30b}
CTX=${2:-65536}
OLLAMA=${OLLAMA_HOST:-http://localhost:11434}
LOCAL_NAME="${MODEL%%:*}-rca-${CTX}"

curl -sf "$OLLAMA/api/version" >/dev/null || { echo "Ollama is not running at $OLLAMA (start it: ollama serve)"; exit 1; }
ollama show "$MODEL" >/dev/null 2>&1 || { echo "Model $MODEL not found. Pull it first: ollama pull $MODEL"; exit 1; }

# Derived model with the bigger context baked in (cheap: shares the weights).
if ! ollama show "$LOCAL_NAME" >/dev/null 2>&1; then
  mf=$(mktemp); printf 'FROM %s\nPARAMETER num_ctx %s\n' "$MODEL" "$CTX" > "$mf"
  ollama create "$LOCAL_NAME" -f "$mf" >/dev/null; rm -f "$mf"
  echo "created $LOCAL_NAME (num_ctx=$CTX)"
fi

export ANTHROPIC_BASE_URL="$OLLAMA"
export ANTHROPIC_AUTH_TOKEN=ollama
export ANTHROPIC_API_KEY=""
# every model slot (main, subagents, background/fast tasks) goes to the local model
export ANTHROPIC_MODEL="$LOCAL_NAME"
export ANTHROPIC_DEFAULT_OPUS_MODEL="$LOCAL_NAME"
export ANTHROPIC_DEFAULT_SONNET_MODEL="$LOCAL_NAME"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="$LOCAL_NAME"
export CLAUDE_CODE_SUBAGENT_MODEL="$LOCAL_NAME"
# no telemetry, error reporting or update checks
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

echo "Claude Code -> $LOCAL_NAME via $OLLAMA (offline mode)"
exec claude --model "$LOCAL_NAME" "${@:3}"
