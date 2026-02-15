#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENTCTL="$SCRIPT_DIR/bin/agentctl"

echo "=== agent-orc setup ==="
echo ""

# 1. Initialize local workspace (.ai-orch/ inside project dir)
echo "Initializing local agentctl workspace..."
python3 "$AGENTCTL" init
echo ""

# 2. Install Codex profiles to ~/.codex/config.toml
CODEX_CONFIG_DIR="$HOME/.codex"
CODEX_CONFIG="$CODEX_CONFIG_DIR/config.toml"
mkdir -p "$CODEX_CONFIG_DIR"

if [ -f "$CODEX_CONFIG" ]; then
    # Check if our profiles already exist
    if grep -q '\[profiles\.spark\]' "$CODEX_CONFIG" 2>/dev/null; then
        echo "Codex profiles (spark/deep/review) already present in $CODEX_CONFIG"
    else
        echo "Appending agentctl profiles (spark/deep/review) to $CODEX_CONFIG"
        echo "" >> "$CODEX_CONFIG"
        echo "# --- agentctl profiles (added by agent-orc installer) ---" >> "$CODEX_CONFIG"
        cat "$SCRIPT_DIR/config/codex-profiles.toml" >> "$CODEX_CONFIG"
    fi
else
    echo "Creating Codex config with agentctl profiles at $CODEX_CONFIG"
    cp "$SCRIPT_DIR/config/codex-config.toml" "$CODEX_CONFIG"
fi

# NOTE: We do NOT touch ~/.codex/AGENTS.md (global).
# Codex chains global + project-level AGENTS.md automatically.
# Put project-specific rules in <repo>/AGENTS.md for each project.

# 3. Done
echo ""
echo "=== Setup complete ==="
echo ""
echo "agentctl data: $SCRIPT_DIR/.ai-orch/"
echo "Codex profiles: $CODEX_CONFIG"
echo ""
echo "To use agentctl from anywhere, add an alias:"
echo "  alias agentctl='python3 $AGENTCTL'"
echo ""
echo "--- AGENTS.md ---"
echo "Codex reads AGENTS.md from two places (both are combined):"
echo "  Global:  ~/.codex/AGENTS.md   (your personal rules, we don't touch this)"
echo "  Project: <repo>/AGENTS.md     (per-project rules)"
echo "Template for project-level AGENTS.md: $SCRIPT_DIR/config/agents-project.md"
echo ""
echo "--- Next steps ---"
echo "  1) agentctl add-project <name> /path/to/repo [--default-profile spark]"
echo "  2) Copy project AGENTS.md to your repos:"
echo "     cp $SCRIPT_DIR/config/agents-project.md /path/to/repo/AGENTS.md"
echo "  3) Ensure tmux is installed: brew install tmux"
echo "  4) Start a tmux session: tmux new -s ai"
echo "  5) Run tasks:"
echo '     agentctl start --project <name> --profile spark <<'"'"'PROMPT'"'"
echo "     Your task prompt here..."
echo "     PROMPT"
