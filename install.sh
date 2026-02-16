#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENTCTL="$SCRIPT_DIR/bin/agentctl"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}+${NC} $1"; }
warn() { echo -e "  ${YELLOW}!${NC} $1"; }
err()  { echo -e "  ${RED}x${NC} $1"; }

detect_os() {
    case "$(uname -s)" in
        Darwin*) echo "macos" ;;
        Linux*)  echo "linux" ;;
        *)       echo "unknown" ;;
    esac
}

detect_pkg_manager() {
    if command -v brew &>/dev/null; then echo "brew"
    elif command -v apt &>/dev/null; then echo "apt"
    elif command -v dnf &>/dev/null; then echo "dnf"
    elif command -v pacman &>/dev/null; then echo "pacman"
    else echo "none"
    fi
}

detect_shell_rc() {
    local shell_name
    shell_name="$(basename "${SHELL:-/bin/bash}")"
    case "$shell_name" in
        zsh)  echo "$HOME/.zshrc" ;;
        bash)
            if [ -f "$HOME/.bash_profile" ]; then
                echo "$HOME/.bash_profile"
            else
                echo "$HOME/.bashrc"
            fi
            ;;
        fish) echo "$HOME/.config/fish/config.fish" ;;
        *)    echo "$HOME/.profile" ;;
    esac
}

check_python() {
    if command -v python3 &>/dev/null; then
        local ver
        ver="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
        local major minor
        major="$(echo "$ver" | cut -d. -f1)"
        minor="$(echo "$ver" | cut -d. -f2)"
        if [ "$major" -ge 3 ] && [ "$minor" -ge 9 ]; then
            ok "Python $ver"
            return 0
        else
            err "Python $ver found (need 3.9+)"
            return 1
        fi
    else
        err "Python 3 not found"
        return 1
    fi
}

check_tmux() {
    if command -v tmux &>/dev/null; then
        ok "tmux $(tmux -V | awk '{print $2}')"
        return 0
    else
        return 1
    fi
}

check_claude() {
    if command -v claude &>/dev/null; then
        ok "claude CLI found"
        return 0
    else
        return 1
    fi
}

check_codex() {
    if command -v codex &>/dev/null; then
        ok "codex CLI found"
        return 0
    else
        return 1
    fi
}

install_tmux() {
    local pkg_mgr="$1"
    case "$pkg_mgr" in
        brew)   brew install tmux ;;
        apt)    sudo apt update && sudo apt install -y tmux ;;
        dnf)    sudo dnf install -y tmux ;;
        pacman) sudo pacman -S --noconfirm tmux ;;
        *)      err "No supported package manager found. Install tmux manually."; return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

OS="$(detect_os)"
PKG_MGR="$(detect_pkg_manager)"

echo -e "${BOLD}=== agent-orc setup ===${NC}"
echo -e "  OS: $OS  Package manager: $PKG_MGR"
echo ""

# --- Python ---
echo -e "${BOLD}--- Checking Python ---${NC}"
if ! check_python; then
    err "Python 3.9+ is required. Install it and try again."
    exit 1
fi
echo ""

# --- tmux ---
echo -e "${BOLD}--- Checking tmux ---${NC}"
if ! check_tmux; then
    warn "tmux not found (needed for interactive mode, not for --headless)"
    if [ "$PKG_MGR" != "none" ]; then
        read -r -p "  Install tmux via $PKG_MGR? [Y/n] " answer
        answer="${answer:-Y}"
        if [[ "$answer" =~ ^[Yy] ]]; then
            install_tmux "$PKG_MGR"
            if check_tmux; then
                echo ""
            else
                warn "tmux installation may have failed. You can still use --headless mode."
            fi
        else
            warn "Skipping tmux. You can still use --headless mode."
        fi
    else
        warn "No package manager detected. Install tmux manually for interactive mode."
    fi
fi
echo ""

# --- Claude Code ---
echo -e "${BOLD}--- Checking Claude Code ---${NC}"
if ! check_claude; then
    warn "claude CLI not found"
    echo "  Install: npm install -g @anthropic-ai/claude-code"
fi
echo ""

# --- Codex CLI ---
echo -e "${BOLD}--- Checking Codex CLI ---${NC}"
if ! check_codex; then
    warn "codex CLI not found"
    echo "  Install: npm install -g @openai/codex"
fi
echo ""

# --- Initialize workspace ---
echo -e "${BOLD}--- Initializing workspace ---${NC}"
python3 "$AGENTCTL" init
echo ""

# --- Codex profiles ---
echo -e "${BOLD}--- Codex profiles ---${NC}"
CODEX_CONFIG_DIR="$HOME/.codex"
CODEX_CONFIG="$CODEX_CONFIG_DIR/config.toml"
mkdir -p "$CODEX_CONFIG_DIR"

if [ -f "$CODEX_CONFIG" ]; then
    if grep -q '\[profiles\.spark\]' "$CODEX_CONFIG" 2>/dev/null; then
        ok "Codex profiles (spark/deep/review) already present"
    else
        echo "" >> "$CODEX_CONFIG"
        echo "# --- agentctl profiles (added by agent-orc installer) ---" >> "$CODEX_CONFIG"
        cat "$SCRIPT_DIR/config/codex-profiles.toml" >> "$CODEX_CONFIG"
        ok "Appended profiles to $CODEX_CONFIG"
    fi
else
    cp "$SCRIPT_DIR/config/codex-config.toml" "$CODEX_CONFIG"
    ok "Created $CODEX_CONFIG with profiles"
fi
echo ""

# --- Shell PATH ---
echo -e "${BOLD}--- Shell aliases ---${NC}"
BIN_DIR="$SCRIPT_DIR/bin"
SHELL_RC="$(detect_shell_rc)"

if echo "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
    ok "agent-orc/bin already in PATH"
else
    read -r -p "  Add $BIN_DIR to PATH in $SHELL_RC? [Y/n] " answer
    answer="${answer:-Y}"
    if [[ "$answer" =~ ^[Yy] ]]; then
        echo "" >> "$SHELL_RC"
        echo "# agent-orc" >> "$SHELL_RC"
        echo "export PATH=\"$BIN_DIR:\$PATH\"" >> "$SHELL_RC"
        ok "Added to $SHELL_RC (restart shell or: source $SHELL_RC)"
    else
        echo "  To add manually:"
        echo "    export PATH=\"$BIN_DIR:\$PATH\""
    fi
fi
echo ""

# --- Done ---
echo -e "${BOLD}=== Setup complete ===${NC}"
echo ""
echo "  orch                        # Claude orchestrator (interactive)"
echo "  orch --bridge               # + Codex worker bridge"
echo "  orch --engine codex         # Codex orchestrator"
echo "  orch --headless -p 'Fix X'  # headless mode"
