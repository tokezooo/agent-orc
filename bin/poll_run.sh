#!/usr/bin/env bash
# Usage: poll_run.sh <run_id> [poll_interval_sec]
# Polls agentctl until the run finishes, then prints the result JSON.
set -u

RUN_ID="${1:?Usage: poll_run.sh <run_id> [interval]}"
INTERVAL="${2:-10}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENTCTL="python3 $SCRIPT_DIR/agentctl"
ORCH_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_DIR="$ORCH_ROOT/.ai-orch/runs/$RUN_ID"

echo "[poll] watching run=$RUN_ID interval=${INTERVAL}s"

while true; do
    # Check if result.json appeared (interactive mode)
    if [ -f "$RUN_DIR/result.json" ]; then
        echo "[poll] result.json found for $RUN_ID"
        # Give _on_finish a moment to update meta
        sleep 2
        $AGENTCTL show "$RUN_ID" 2>&1
        exit 0
    fi

    # Check meta status (headless mode or _on_finish already ran)
    STATUS=$($AGENTCTL show "$RUN_ID" 2>&1 | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','unknown'))" 2>/dev/null || echo "unknown")
    if [ "$STATUS" = "finished" ]; then
        echo "[poll] run $RUN_ID finished (meta)"
        $AGENTCTL show "$RUN_ID" 2>&1
        exit 0
    fi

    sleep "$INTERVAL"
done
