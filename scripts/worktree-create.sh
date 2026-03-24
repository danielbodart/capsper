#!/usr/bin/env bash
set -euo pipefail

# Claude Code WorktreeCreate hook: creates a git worktree and runs setup.
# Input: JSON on stdin with "name" and "cwd" fields.
# Output: worktree absolute path on stdout (required by Claude Code).
# All other output goes to stderr so it doesn't corrupt the path.

INPUT=$(cat)
NAME=$(echo "$INPUT" | jq -r '.name')
CWD=$(echo "$INPUT" | jq -r '.cwd')

WORKTREE_DIR="$CWD/.claude/worktrees/$NAME"

# Create the git worktree with a new branch based on HEAD
git -C "$CWD" worktree add -b "$NAME" "$WORKTREE_DIR" HEAD >&2

# Symlink model directories (not in git, downloaded at install time)
for model_name in nemotron nemotron-coreml; do
    MAIN_MODEL_DIR="$CWD/dist/models/$model_name"
    WT_MODEL_DIR="$WORKTREE_DIR/dist/models/$model_name"
    if [ -d "$MAIN_MODEL_DIR" ] && [ ! -e "$WT_MODEL_DIR" ]; then
        mkdir -p "$(dirname "$WT_MODEL_DIR")"
        ln -s "$MAIN_MODEL_DIR" "$WT_MODEL_DIR" >&2 && echo "Symlinked $model_name model" >&2
    fi
done

# Run the standard setup (LFS, mise, dependencies, build, tests)
cd "$WORKTREE_DIR"
./run.ts >&2

# Print the worktree path (this is what Claude Code reads)
echo "$WORKTREE_DIR"
