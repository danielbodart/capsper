#!/usr/bin/env bash
set -euo pipefail

# Claude Code WorktreeRemove hook: deinit submodules then remove the worktree.
# Input: JSON on stdin with "worktree_path" and "cwd" fields.
# All output goes to stderr (no stdout protocol for remove hooks).

INPUT=$(cat)
WORKTREE_PATH=$(echo "$INPUT" | jq -r '.worktree_path')
CWD=$(echo "$INPUT" | jq -r '.cwd')

# Change to main repo BEFORE removal so the shell doesn't lose its CWD
cd "$CWD"

if [ ! -d "$WORKTREE_PATH" ]; then
    echo "Worktree already removed: $WORKTREE_PATH" >&2
    exit 0
fi

# Deinit submodules so git worktree remove succeeds
if [ -f "$WORKTREE_PATH/.gitmodules" ]; then
    echo "Deinitializing submodules..." >&2
    git -C "$WORKTREE_PATH" submodule deinit --all --force >&2 2>/dev/null || true
fi

# Also remove any nested .git dirs that block worktree removal
find "$WORKTREE_PATH" -mindepth 2 -name .git -type d -exec rm -rf {} + 2>/dev/null || true
find "$WORKTREE_PATH" -mindepth 2 -name .git -type f -exec rm -f {} + 2>/dev/null || true

# Remove the worktree
git worktree remove --force "$WORKTREE_PATH" >&2
echo "Removed worktree: $WORKTREE_PATH" >&2
