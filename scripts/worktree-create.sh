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

# Symlink the large whisper model (574 MB, not in git)
MAIN_MODEL="$CWD/dist/models/ggml-large-v3-turbo-q5_0.bin"
WT_MODEL="$WORKTREE_DIR/dist/models/ggml-large-v3-turbo-q5_0.bin"
if [ -f "$MAIN_MODEL" ] && [ ! -e "$WT_MODEL" ]; then
    mkdir -p "$(dirname "$WT_MODEL")"
    ln -s "$MAIN_MODEL" "$WT_MODEL" >&2 && echo "Symlinked whisper model" >&2
fi

# Run the standard setup (LFS, mise, dependencies, build, tests)
cd "$WORKTREE_DIR"
./run.ts >&2

# Print the worktree path (this is what Claude Code reads)
echo "$WORKTREE_DIR"
