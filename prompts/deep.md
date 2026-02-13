# TASK
<что сделать>

# Expectations
- First: identify the root cause / architecture impact.
- Then: implement a safe fix with tests (or at least a verification command).
- Prefer incremental commits/checkpoints (if you choose to create them, mention it).

# Acceptance
- <tests/lint + функциональное условие>

# Output (STRICT)
Return ONLY JSON with keys:
goal_met (bool), summary (string), followup_prompt (string), notes (string)
