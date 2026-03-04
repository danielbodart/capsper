#!/bin/bash
# PreToolUse hook: require human approval for .test.json edits
# These files contain regression test thresholds that must not be
# changed without presenting before/after results to a human.
set -euo pipefail

input=$(cat)
file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty')

if [[ "$file_path" == *.test.json ]]; then
    cat <<'EOF'
{"hookSpecificOutput":{"permissionDecision":"ask"},"systemMessage":"BLOCKED: Editing test threshold file requires human approval. Present the before/after results and get explicit sign-off before modifying."}
EOF
fi
