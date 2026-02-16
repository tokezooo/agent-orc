#!/usr/bin/env bash
#
# Integration test for codex-bridge.
# Tests the full lifecycle WITHOUT requiring Codex CLI or tmux.
# Uses a mock agentctl that returns canned results.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
BRIDGE="$REPO_DIR/bin/codex-bridge"

TEAM="test-bridge-$$"
WORKER="codex-test-worker"
LEADER="test-leader"

TEAM_DIR="$HOME/.claude/teams/$TEAM"
TASKS_DIR="$HOME/.claude/tasks/$TEAM"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; FAILURES=$((FAILURES + 1)); }
FAILURES=0

cleanup() {
    # Kill bridge if running
    [ -n "${BRIDGE_PID:-}" ] && kill "$BRIDGE_PID" 2>/dev/null && wait "$BRIDGE_PID" 2>/dev/null || true
    rm -rf "$TEAM_DIR" "$TASKS_DIR" "$MOCK_AGENTCTL"
}
trap cleanup EXIT

echo -e "${BOLD}=== codex-bridge integration test ===${NC}"
echo "  Team:   $TEAM"
echo "  Worker: $WORKER"
echo ""

# -----------------------------------------------------------------------
# Setup: create mock agentctl
# -----------------------------------------------------------------------
MOCK_AGENTCTL="$(mktemp)"
cat > "$MOCK_AGENTCTL" << 'MOCK'
#!/usr/bin/env python3
"""Mock agentctl: returns canned success for start+wait.
Accepts --worktree / --no-worktree flags (ignored in mock).
"""
import sys, json, time

# Filter out --worktree / --no-worktree so they don't interfere with arg parsing
args = [a for a in sys.argv[1:] if a not in ("--worktree", "--no-worktree")]
cmd = args[0] if args else ""

if cmd == "start":
    print("mock-run-001")
elif cmd == "wait":
    time.sleep(0.5)  # simulate short work
    print(json.dumps({
        "run_id": "mock-run-001",
        "status": "finished",
        "goal_met": True,
        "summary": "Fixed the bug successfully",
        "exit_code": 0,
        "git_diff_stat": "1 file changed, 3 insertions(+), 1 deletion(-)",
        "profile": "spark",
    }))
elif cmd == "show":
    run_id = args[1] if len(args) > 1 else "unknown"
    print(json.dumps({"run_id": run_id, "status": "finished", "goal_met": True}))
else:
    print(f"mock: unknown command {cmd}", file=sys.stderr)
    sys.exit(1)
MOCK
chmod +x "$MOCK_AGENTCTL"

# -----------------------------------------------------------------------
# Setup: create team directory with leader already registered
# -----------------------------------------------------------------------
mkdir -p "$TEAM_DIR/inboxes" "$TASKS_DIR"

cat > "$TEAM_DIR/config.json" << EOF
{
  "members": [
    {
      "agentId": "$LEADER@$TEAM",
      "name": "$LEADER",
      "agentType": "claude-code",
      "isActive": true
    }
  ]
}
EOF

# Create leader's inbox
echo "[]" > "$TEAM_DIR/inboxes/$LEADER.json"

echo -e "${BOLD}--- Test 1: join (register) ---${NC}"

# Patch AGENTCTL path in bridge to use our mock
# We do this by setting the bridge's AGENTCTL via env + a wrapper
BRIDGE_WRAPPER="$(mktemp)"
cat > "$BRIDGE_WRAPPER" << EOF
#!/usr/bin/env python3
import sys
sys.path.insert(0, '.')

import importlib.machinery, importlib.util
loader = importlib.machinery.SourceFileLoader('codex_bridge', '$BRIDGE')
spec = importlib.util.spec_from_loader('codex_bridge', loader)
cb = importlib.util.module_from_spec(spec)

# Patch AGENTCTL before exec
import types
original_source = open('$BRIDGE').read()
patched_source = original_source.replace(
    "AGENTCTL = Path(__file__).resolve().parent / \"agentctl\"",
    "AGENTCTL = Path(\"$MOCK_AGENTCTL\")"
)
exec(compile(patched_source, '$BRIDGE', 'exec'), cb.__dict__)

# Run with args
sys.argv = ['codex-bridge'] + sys.argv[1:]
cb.main()
EOF
chmod +x "$BRIDGE_WRAPPER"

# Start bridge in background
python3 "$BRIDGE_WRAPPER" join \
    --team "$TEAM" \
    --name "$WORKER" \
    --project /tmp \
    --poll-interval 1 \
    --task-timeout 30 \
    > /tmp/bridge-test-$$.log 2>&1 &
BRIDGE_PID=$!
sleep 3  # wait for bridge's _wait_for_team (1s sleep) + registration

# Check: worker registered in config.json
if python3 -c "
import json
cfg = json.load(open('$TEAM_DIR/config.json'))
members = {m['name']: m for m in cfg['members']}
w = members.get('$WORKER')
assert w is not None, 'worker not in members'
assert w['isActive'] == True, 'not active'
assert w['agentType'] == 'codex-bridge'
"; then
    pass "Worker registered in config.json (isActive=true, agentType=codex-bridge)"
else
    fail "Worker not registered correctly"
fi

# Check: inbox created
if [ -f "$TEAM_DIR/inboxes/$WORKER.json" ]; then
    pass "Worker inbox file created"
else
    fail "Worker inbox file missing"
fi

# -----------------------------------------------------------------------
echo -e "\n${BOLD}--- Test 2: task pickup + execution ---${NC}"

# Create a pending task assigned to our worker
cat > "$TASKS_DIR/1.json" << EOF
{
  "id": "1",
  "subject": "Fix null pointer in auth.ts",
  "description": "The auth middleware crashes when token is undefined. Add a null check.",
  "status": "pending",
  "owner": "$WORKER",
  "activeForm": "Fixing null pointer",
  "blockedBy": [],
  "blocks": []
}
EOF

# Wait for bridge to pick it up and process
echo "  Waiting for bridge to process task..."
for i in $(seq 1 15); do
    STATUS=$(python3 -c "import json; t=json.load(open('$TASKS_DIR/1.json')); print(t.get('status',''))" 2>/dev/null || echo "error")
    if [ "$STATUS" = "completed" ]; then
        break
    fi
    sleep 1
done

if [ "$STATUS" = "completed" ]; then
    pass "Task #1 status changed to 'completed'"
else
    fail "Task #1 status is '$STATUS' (expected 'completed')"
fi

# Check: result posted to leader's inbox
INBOX_COUNT=$(python3 -c "import json; msgs=json.load(open('$TEAM_DIR/inboxes/$LEADER.json')); print(len(msgs))" 2>/dev/null || echo "0")
if [ "$INBOX_COUNT" -ge 1 ]; then
    pass "Result message posted to leader's inbox ($INBOX_COUNT message(s))"
else
    fail "No message in leader's inbox"
fi

# Check inbox message content
if python3 -c "
import json
msgs = json.load(open('$TEAM_DIR/inboxes/$LEADER.json'))
msg = msgs[-1]
assert msg['from'] == '$WORKER', f'from={msg[\"from\"]}'
assert 'COMPLETED' in msg['text'], 'no COMPLETED tag'
assert 'Fixed the bug' in msg['text'], 'summary missing'
assert msg['read'] == False
"; then
    pass "Inbox message has correct format (from, text, read=false)"
else
    fail "Inbox message format incorrect"
fi

# -----------------------------------------------------------------------
echo -e "\n${BOLD}--- Test 3: blocked task is skipped ---${NC}"

# Reset leader inbox
echo "[]" > "$TEAM_DIR/inboxes/$LEADER.json"

# Create a blocked task
cat > "$TASKS_DIR/2.json" << EOF
{
  "id": "2",
  "subject": "Deploy to staging",
  "description": "Deploy after tests pass",
  "status": "pending",
  "owner": "$WORKER",
  "blockedBy": ["99"],
  "blocks": []
}
EOF

# Create the blocker (not completed)
cat > "$TASKS_DIR/99.json" << EOF
{
  "id": "99",
  "subject": "Run tests",
  "status": "in_progress",
  "owner": "someone-else"
}
EOF

sleep 3

# Task 2 should still be pending (blocked)
STATUS2=$(python3 -c "import json; t=json.load(open('$TASKS_DIR/2.json')); print(t.get('status',''))" 2>/dev/null || echo "error")
if [ "$STATUS2" = "pending" ]; then
    pass "Blocked task #2 was NOT picked up (still pending)"
else
    fail "Blocked task #2 status is '$STATUS2' (expected 'pending')"
fi

# -----------------------------------------------------------------------
echo -e "\n${BOLD}--- Test 4: profile auto-selection ---${NC}"

# Create a task with "refactor" keyword → should trigger deep profile
cat > "$TASKS_DIR/3.json" << EOF
{
  "id": "3",
  "subject": "Refactor authentication module",
  "description": "Extract common auth logic into shared utils",
  "status": "pending",
  "owner": "$WORKER",
  "blockedBy": [],
  "blocks": []
}
EOF

sleep 4

STATUS3=$(python3 -c "import json; t=json.load(open('$TASKS_DIR/3.json')); print(t.get('status',''))" 2>/dev/null || echo "error")
if [ "$STATUS3" = "completed" ]; then
    pass "Task #3 (with 'refactor' keyword) completed"
else
    fail "Task #3 status is '$STATUS3' (expected 'completed')"
fi

# Check bridge log for "deep" profile
if grep -q "profile=deep" /tmp/bridge-test-$$.log 2>/dev/null; then
    pass "Bridge auto-selected 'deep' profile for refactor task"
else
    fail "Bridge did not select 'deep' profile (check /tmp/bridge-test-$$.log)"
fi

# -----------------------------------------------------------------------
echo -e "\n${BOLD}--- Test 5: shutdown via inbox message ---${NC}"

# Post a shutdown request to the worker's inbox
python3 -c "
import json
msgs = json.load(open('$TEAM_DIR/inboxes/$WORKER.json'))
msgs.append({
    'from': '$LEADER',
    'text': json.dumps({'type': 'shutdown_request', 'requestId': 'test-req-1'}),
    'summary': 'Shutdown',
    'timestamp': '2026-02-15T00:00:00.000Z',
    'read': False
})
with open('$TEAM_DIR/inboxes/$WORKER.json', 'w') as f:
    json.dump(msgs, f)
"

# Wait for bridge to exit
for i in $(seq 1 10); do
    if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
        break
    fi
    sleep 1
done

if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
    pass "Bridge exited after shutdown_request"
else
    fail "Bridge still running after shutdown_request"
fi

# Check: worker deregistered
if python3 -c "
import json
cfg = json.load(open('$TEAM_DIR/config.json'))
for m in cfg['members']:
    if m['name'] == '$WORKER':
        assert m['isActive'] == False, 'still active'
        break
"; then
    pass "Worker deregistered (isActive=false) after shutdown"
else
    fail "Worker still active after shutdown"
fi

# -----------------------------------------------------------------------
echo -e "\n${BOLD}--- Test 6: leave command ---${NC}"

# Re-register, then leave
python3 "$BRIDGE_WRAPPER" leave --team "$TEAM" --name "$WORKER" > /dev/null 2>&1
# leave sets isActive=false (already false, but test the command works)
pass "codex-bridge leave executed without error"

# -----------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------
echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo -e "${GREEN}${BOLD}All tests passed!${NC}"
else
    echo -e "${RED}${BOLD}$FAILURES test(s) failed.${NC}"
    echo ""
    echo "Bridge log: /tmp/bridge-test-$$.log"
fi

# Show bridge log on failure
if [ "$FAILURES" -gt 0 ]; then
    echo ""
    echo "--- Bridge log ---"
    cat /tmp/bridge-test-$$.log 2>/dev/null || true
fi

rm -f "$BRIDGE_WRAPPER"
exit "$FAILURES"
