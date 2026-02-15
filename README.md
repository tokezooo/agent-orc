# agent-orc

Lightweight tmux orchestrator for running parallel [Codex CLI](https://github.com/openai/codex) agents from a single [Claude Code](https://docs.anthropic.com/en/docs/claude-code) session.

One Opus window decomposes tasks, spawns 8-10 Codex workers in tmux panes, and collects structured JSON results &mdash; all without blocking itself.

```
┌─────────────────────────────────────────────────────────────┐
│  tmux session "ai"                                          │
│                                                             │
│  ┌─────────────────────┐  ┌──────────────────────────────┐  │
│  │                     │  │  codex (spark) ── task #1    │  │
│  │  Claude Code        │  ├──────────────────────────────┤  │
│  │  (Orchestrator)     │  │  codex (deep)  ── task #2    │  │
│  │                     │  ├──────────────────────────────┤  │
│  │  agentctl start ... │  │  codex (spark) ── task #3    │  │
│  │  agentctl wait  ... │  ├──────────────────────────────┤  │
│  │  agentctl show  ... │  │  codex (review) ── task #4   │  │
│  │                     │  ├──────────────────────────────┤  │
│  │                     │  │  ...more agents...           │  │
│  └─────────────────────┘  └──────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## Why

AI coding agents work best on focused, well-scoped subtasks. But you still need something to break down the work, route it to the right model, and handle failures.

**agent-orc** lets Claude Code (Opus) act as an orchestrator that:

- **Decomposes** a user request into 1-5 subtasks
- **Routes** each subtask to the right Codex profile (fast `spark` vs deep `deep` vs read-only `review`)
- **Runs** them in parallel via tmux panes
- **Collects** structured JSON results (`goal_met`, `summary`, `followup_prompt`)
- **Escalates** failures automatically (spark fails &rarr; retry with deep)
- **Stays unblocked** the whole time &mdash; you keep chatting while agents work

## Features

- **Zero dependencies** &mdash; pure Python 3.9+, no pip install
- **Non-blocking workflow** &mdash; `agentctl wait` runs in background, orchestrator stays free
- **Structured output** &mdash; JSON schema enforces `{goal_met, summary, followup_prompt, notes}`
- **Profile routing** &mdash; spark (fast/cheap), deep (high reasoning), review (read-only)
- **Session resume** &mdash; continue a Codex session with follow-up prompts
- **tmux notifications** &mdash; display-message + optional send-keys to wake the orchestrator
- **Git-aware** &mdash; captures `git diff --stat` after each run

## Quick Start

### Prerequisites

- [Codex CLI](https://github.com/openai/codex) installed and authenticated
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed
- [tmux](https://github.com/tmux/tmux) installed
- Python 3.9+

### Install

```bash
git clone https://github.com/user/agent-orc.git
cd agent-orc
./install.sh
```

This will:
1. Initialize the `.ai-orch/` workspace (run data, config, schema)
2. Add Codex profiles (`spark`, `deep`, `review`) to `~/.codex/config.toml`

Add an alias for convenience:

```bash
echo "alias agentctl='python3 $(pwd)/bin/agentctl'" >> ~/.zshrc
source ~/.zshrc
```

### Register your projects

```bash
agentctl add-project myapp ~/projects/myapp --default-profile spark
agentctl add-project backend ~/projects/backend --default-profile deep
```

### Launch the orchestrator

```bash
tmux new -s ai
bin/orch                    # starts Claude Code with orchestrator prompt
# or
bin/orch ~/projects/myapp   # start in a specific directory
```

Now give Claude Code a task. It will decompose it and spawn Codex agents automatically.

## How It Works

### 1. Start agents

```bash
RUN_ID=$(agentctl start --project myapp --profile spark --title "Fix auth bug" <<'PROMPT'
# TASK
Fix the failing authentication test in tests/auth.test.ts

# Acceptance
- All tests pass
- No unrelated changes

# Output (STRICT)
Return ONLY JSON: {goal_met, summary, followup_prompt, notes}
PROMPT
)
# Returns instantly: 20260215-143022-ab12
```

### 2. Wait in background (non-blocking)

```bash
# This blocks until the run finishes, but runs in background
agentctl wait $RUN_ID &
# Orchestrator is free to launch more agents, answer questions, etc.
```

### 3. Check results

```bash
agentctl show $RUN_ID
```

```json
{
  "run_id": "20260215-143022-ab12",
  "status": "finished",
  "goal_met": true,
  "summary": "Fixed missing token validation in auth middleware. All 47 tests pass.",
  "exit_code": 0,
  "git_diff_stat": "2 files changed, 15 insertions(+), 3 deletions(-)"
}
```

### 4. Handle failures

If `goal_met: false`, escalate with a follow-up:

```bash
agentctl resume --parent-run-id $RUN_ID --profile deep <<'PROMPT'
Previous spark attempt failed. Root cause analysis needed.
...
PROMPT
```

## Commands

| Command | Description |
|---------|-------------|
| `agentctl init` | Initialize workspace (`.ai-orch/`) |
| `agentctl add-project <name> <path>` | Register a project |
| `agentctl start --project <name>` | Launch a Codex agent in a tmux pane |
| `agentctl wait <run_id>` | Block until run finishes, print result JSON |
| `agentctl show <run_id>` | Show run metadata |
| `agentctl list` | List recent runs |
| `agentctl resume --parent-run-id <id>` | Continue a session with follow-up prompt |
| `agentctl tail` | Live-tail the notification log |

## Profiles

Profiles are defined in `~/.codex/config.toml` and control model selection, reasoning effort, and permissions:

| Profile | Model | Reasoning | Use Case |
|---------|-------|-----------|----------|
| **spark** | codex-spark | low | Fast edits, single-file fixes, quick checks |
| **deep** | codex | xhigh | Architecture, multi-file changes, complex bugs |
| **review** | codex | medium | Read-only code review, no file modifications |

See [`config/codex-config.toml`](config/codex-config.toml) for the full template.

## Project Structure

```
agent-orc/
  bin/
    agentctl           # Main orchestrator CLI (Python 3, no deps)
    orch               # Bash wrapper — launches Claude Code with system prompt
    poll_run.sh        # Poll utility (legacy, prefer `agentctl wait`)
  config/
    codex-config.toml  # Full Codex config template
    codex-profiles.toml # Profiles only (for appending to existing config)
    agents-project.md  # Template for per-project AGENTS.md
  prompts/
    orchestrator.md    # System prompt for the Claude Code orchestrator
    spark.md           # Prompt template for spark tasks
    deep.md            # Prompt template for deep tasks
    review.md          # Prompt template for review tasks
  install.sh           # One-time setup script
  .ai-orch/            # Runtime data (gitignored)
    config.json        # tmux session settings
    projects.json      # Registered projects
    runs/              # Per-run artifacts (meta, prompt, events, output)
    notify.log         # Completion log
```

## Orchestrator Prompt

The orchestrator system prompt ([`prompts/orchestrator.md`](prompts/orchestrator.md)) teaches Claude Code to:

1. Decompose tasks into 1-5 subtasks
2. Route each to the right profile
3. Launch agents via `agentctl start`
4. Monitor via `agentctl wait` (background) + `agentctl show`
5. Report results as short status lines
6. Escalate failures (spark &rarr; deep)

You can customize it or write your own.

## Notifications

When a run finishes, `agentctl` writes to `.ai-orch/notify.log` and optionally sends tmux notifications:

```json
// .ai-orch/config.json
{
  "tmux_session": "ai",
  "tmux_notify_target": "ai:0",
  "tmux_sendkeys_target": "ai:0.0"
}
```

- `tmux_notify_target` &mdash; tmux `display-message` target (status bar flash)
- `tmux_sendkeys_target` &mdash; tmux `send-keys` target (injects text into orchestrator pane to wake it up)

## License

[MIT](LICENSE)
