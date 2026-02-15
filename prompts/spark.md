# TASK
<one sentence: what to do>

# Context
- Repo: current directory
- Goal: <what counts as "done">

# Constraints
- Minimal diff.
- Prefer surgical changes.
- Run only fast checks.

# Acceptance
- <1-3 items>

# If blocked
If anything is ambiguous or needs deeper analysis, set goal_met=false and write followup_prompt for a deep session.

# Output (STRICT)
Return ONLY JSON with keys:
goal_met (bool), summary (string), followup_prompt (string), notes (string)
