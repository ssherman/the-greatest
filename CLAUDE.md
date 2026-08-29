@AGENTS.md

## Claude Code specifics

This file is only for instructions that would mislead an agent without Claude Code's tools.
Everything else goes in `AGENTS.md`, imported above.

**Worktrees: use the `EnterWorktree` tool. Never `git worktree add`, never a hand-written worktree
script.** The harness owns placement (`.claude/worktrees/<name>`, already gitignored), branch
creation, cleanup, and copying in the gitignored files a checkout needs. Bypassing it creates
worktrees the harness cannot see or clean up.
