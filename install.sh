#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENTCTL_SRC="$SCRIPT_DIR/bin/agentctl"
AGENTCTL_DST="$HOME/bin/agentctl"

echo "=== agent-orc installer ==="
echo ""

# 1. Ensure ~/bin exists
mkdir -p "$HOME/bin"

# 2. Copy agentctl
if [ -f "$AGENTCTL_DST" ]; then
    echo "Existing agentctl found at $AGENTCTL_DST"
    echo "Backing up to ${AGENTCTL_DST}.bak"
    cp "$AGENTCTL_DST" "${AGENTCTL_DST}.bak"
fi
cp "$AGENTCTL_SRC" "$AGENTCTL_DST"
chmod +x "$AGENTCTL_DST"
echo "Installed agentctl -> $AGENTCTL_DST"

# 3. Ensure ~/bin is in PATH
SHELL_RC=""
if [ -f "$HOME/.zshrc" ]; then
    SHELL_RC="$HOME/.zshrc"
elif [ -f "$HOME/.bashrc" ]; then
    SHELL_RC="$HOME/.bashrc"
fi

if [ -n "$SHELL_RC" ]; then
    if ! grep -q 'export PATH="$HOME/bin:$PATH"' "$SHELL_RC" 2>/dev/null; then
        echo '' >> "$SHELL_RC"
        echo '# agentctl (agent-orc)' >> "$SHELL_RC"
        echo 'export PATH="$HOME/bin:$PATH"' >> "$SHELL_RC"
        echo "Added ~/bin to PATH in $SHELL_RC"
    else
        echo "~/bin already in PATH ($SHELL_RC)"
    fi
else
    echo "WARNING: Could not find .zshrc or .bashrc. Add ~/bin to PATH manually."
fi

# 4. Initialize agentctl workspace
echo ""
echo "Initializing agentctl workspace..."
export PATH="$HOME/bin:$PATH"
agentctl init

# 5. Copy config templates (with confirmation)
echo ""
CODEX_CONFIG_DIR="$HOME/.codex"
if [ ! -d "$CODEX_CONFIG_DIR" ]; then
    mkdir -p "$CODEX_CONFIG_DIR"
fi

CODEX_CONFIG="$CODEX_CONFIG_DIR/config.toml"
if [ -f "$CODEX_CONFIG" ]; then
    echo "Existing Codex config found at $CODEX_CONFIG (not overwriting)"
    echo "Template available at: $SCRIPT_DIR/config/codex-config.toml"
else
    cp "$SCRIPT_DIR/config/codex-config.toml" "$CODEX_CONFIG"
    echo "Installed Codex config -> $CODEX_CONFIG"
fi

CODEX_AGENTS="$CODEX_CONFIG_DIR/AGENTS.md"
if [ -f "$CODEX_AGENTS" ]; then
    echo "Existing global AGENTS.md found at $CODEX_AGENTS (not overwriting)"
    echo "Template available at: $SCRIPT_DIR/config/agents-global.md"
else
    cp "$SCRIPT_DIR/config/agents-global.md" "$CODEX_AGENTS"
    echo "Installed global AGENTS.md -> $CODEX_AGENTS"
fi

# 6. Done
echo ""
echo "=== Installation complete ==="
echo ""
echo "Next steps:"
echo "  1) source $SHELL_RC  (or open a new terminal)"
echo "  2) agentctl add-project <name> /path/to/repo [--default-profile spark]"
echo "  3) Ensure tmux is installed: brew install tmux"
echo "  4) Start a tmux session: tmux new -s ai"
echo "  5) Run tasks:"
echo '     agentctl start --project <name> --profile spark <<"PROMPT"'
echo "     Your task prompt here..."
echo "     PROMPT"
