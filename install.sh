#!/usr/bin/env bash
# Install the linux-l3-rca agent and linux-outage-rca skill into ~/.claude
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p ~/.claude/agents ~/.claude/skills
cp agents/linux-l3-rca.md ~/.claude/agents/
rm -rf ~/.claude/skills/linux-outage-rca
cp -R skills/linux-outage-rca ~/.claude/skills/
chmod +x ~/.claude/skills/linux-outage-rca/scripts/*.sh
echo "installed: ~/.claude/agents/linux-l3-rca.md, ~/.claude/skills/linux-outage-rca/ — restart Claude Code"
