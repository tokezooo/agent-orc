#!/usr/bin/env bash
# Usage: poll_run.sh <run_id> [poll_interval_sec]
# Polls agentctl until the run finishes, then prints the result JSON.
set -euo pipefail

RUN_ID="${1:?Usage: poll_run.sh <run_id> [interval]}"
INTERVAL="${2:-10}"

# Validate RUN_ID to prevent path traversal
if [[ ! "$RUN_ID" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "Error: invalid RUN_ID format: $RUN_ID" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENTCTL="$SCRIPT_DIR/agentctl"
ORCH_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_DIR="$ORCH_ROOT/.ai-orch/runs/$RUN_ID"

echo "[poll] watching run=$RUN_ID interval=${INTERVAL}s"

START_TIME="$(date +%s)"
MAX_RUNTIME=7200

while true; do
    # Check for timeout
    ELAPSED=$(( $(date +%s) - START_TIME ))
    if [ "$ELAPSED" -ge "$MAX_RUNTIME" ]; then
        echo "[poll] timeout after ${ELAPSED}s waiting for run=$RUN_ID" >&2
        exit 1
    fi

    # Check if result.json appeared (interactive mode)
    if [ -f "$RUN_DIR/result.json" ]; then
        echo "[poll] result.json found for $RUN_ID"
        # Give _on_finish a moment to update meta
        sleep 2
        python3 "$AGENTCTL" show "$RUN_ID" 2>&1
        exit 0
    fi

    # Check meta status (headless mode or _on_finish already ran)
    STATUS=$(python3 "$AGENTCTL" show "$RUN_ID" 2>&1 | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','unknown'))" 2>/dev/null || echo "unknown")
    if [ "$STATUS" = "finished" ]; then
        echo "[poll] run $RUN_ID finished (meta)"
        python3 "$AGENTCTL" show "$RUN_ID" 2>&1
        exit 0
    fi

    sleep "$INTERVAL"
done
