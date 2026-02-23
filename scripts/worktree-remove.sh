#!/usr/bin/env bash
set -euo pipefail

# Claude Code WorktreeRemove hook: deinit submodules so Claude's built-in
# `git worktree remove` can succeed (it fails on worktrees with submodules).
# Input: JSON on stdin with "worktree_path" and "cwd" fields.
# Claude Code runs `git worktree remove` AFTER this hook — we just prep.

INPUT=$(cat)
WORKTREE_PATH=$(echo "$INPUT" | jq -r '.worktree_path')

if [ ! -d "$WORKTREE_PATH" ]; then
    echo "Worktree already removed: $WORKTREE_PATH" >&2
    exit 0
fi

# Deinit submodules so git worktree remove succeeds
if [ -f "$WORKTREE_PATH/.gitmodules" ]; then
    echo "Deinitializing submodules..." >&2
    git -C "$WORKTREE_PATH" submodule deinit --all --force >&2 2>/dev/null || true
fi

# Remove any nested .git dirs that also block worktree removal
find "$WORKTREE_PATH" -mindepth 2 -name .git -type d -exec rm -rf {} + 2>/dev/null || true
find "$WORKTREE_PATH" -mindepth 2 -name .git -type f -exec rm -f {} + 2>/dev/null || true

echo "Submodules cleaned for: $WORKTREE_PATH" >&2
