# TASK
Review the current git diff for correctness, edge cases, and regressions.
Suggest any minimal improvements.

# Constraints
- Do not modify files (read-only).
- Prefer actionable checklist.

# Output (STRICT)
Return ONLY JSON with:
goal_met=true/false (true if changes look good),
summary,
followup_prompt (if changes are not acceptable),
notes (risks + suggested fixes).
