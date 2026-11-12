# Session cleanup

Scripts that free disk from Claude Code sessions. No skill runs them for cleanup. Hooks and the daily job run them.

| Script | Run by | What it does |
|---|---|---|
| `ledger_hook.py` | `PostToolUse` hook on `Bash` and `EnterWorktree` | Records each simulator, worktree, and `-derivedDataPath` folder that a session creates. |
| `archive_hook.py` | `SessionEnd` hook, and `PostToolUse` hook on `archive_session` | When a session is archived, runs `cleanup.py --apply --final` for it. |
| `cleanup.py` | the hooks, the daily job, `/rollup` (read-only check), `/report` (read-only check) | Removes what a session owns. Prints the git and PR state as JSON. |

The hooks are in `~/dotfiles/common/.claude/settings.json`.
The daily job is the scheduled task "Daily dev disk cleanup" (`worktree-cleanup-daily`).

## Ledger

The ledger is `~/.claude/session-ledgers/<session id>/ledger.jsonl`.
`cleanup.py` removes only items in the ledger. The one exception: it also removes items that nobody can own.
These are "unavailable" simulators and DerivedData whose project no longer exists.
The app's own worktrees are not in the ledger. The daily job handles them.

## cleanup.py modes

- No flags: dry run. Prints the actions and the git and PR state. It changes nothing.
- `--apply`: removes shut-down ledger simulators and clean, pushed ledger worktrees.
- `--apply --final`: the session ended. Also deletes its ledger DerivedData and its booted simulators.
  A recorded DerivedData path is kept when it is home, the cwd, a repo, an ancestor of these, or holds a project.
  The cwd's default DerivedData is not deleted, because another session can share the cwd. The sweep deletes it later.
- `--apply` holds a per-session lock. If the simulator list fails, the script changes nothing and exits 2.
- A git query that fails gives `git.error` and a null field. Callers treat it as unverified, not clean.
- The ledger hook records a worktree or `-derivedDataPath` folder only when this Bash call created it, and skips commands with `||` or `if`.
- The JSON `pr` is null for no PR, and has `state: UNKNOWN` when the lookup failed. `worktrees` has the git and PR state of each ledger worktree.
- `--session <id> --cwd <dir>`: act for a different session.
- `--sweep [--apply]`: machine-wide. Deletes stale worktree DerivedData and old session-named simulators that no ledger owns. Only the daily job uses it.

## Logs

- `~/.claude/session-ledgers/archive-hook.log`: one line for each archive hook call.
- `~/.claude/session-ledgers/<id>/archive-cleanup.json`: output of the final cleanup.
- `~/Development/worktree-cleanup.log`: daily job results.
