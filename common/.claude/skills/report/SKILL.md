---
name: report
description: Write a status report of this session's work, with its in-flight state. Use when the user types /report, asks for the status of this session, or when /rollup asks this session for a report. It changes nothing. Cleanup happens automatically when the session is archived.
---

# Report

Write a status report of the work in this session. Do not clean up anything.
When a session is archived, a hook removes its simulators, worktrees, and DerivedData. See `~/.claude/session-cleanup/README.md`.

## Procedure

1. Get the git and PR state. This is a dry run. It changes nothing.
   ```bash
   python3 -I ~/.claude/session-cleanup/cleanup.py --no-orphans
   ```
   Read `git` and `pr` for the cwd, and `worktrees` for each ledger worktree. Ignore `actions`.
   Apply the in-flight rules to the cwd AND to each entry in `worktrees`.
   A `pr.state` of `UNKNOWN` means the lookup failed. Count it as in-flight, with the reason "PR state unknown".
2. Collect the status of the work in this session:
   - What did the session do? Use the conversation and the git log of the branch.
   - What work remains? Include failing tests, open review comments, and unanswered questions.
   - What are the next steps? Give the person who acts on each step: the user or Claude.
   - Is there in-flight work? Use the rules below.
3. Write the report to `~/.claude/session-ledgers/$CLAUDE_CODE_HOST_SESSION_ID/report.md` in the format below.
4. Post the same report as the reply.

## In-flight work

The session has in-flight work if one or more of these is true:
- A background task, subagent, or child session still runs.
- The session waits for an answer from the user.
- The cwd or a ledger worktree has uncommitted changes.
- The cwd or a ledger worktree has commits that are not pushed, or has no upstream and is not merged.
- The cwd or a ledger worktree has an open PR, or a PR state of `UNKNOWN`.

## Report format

Use this format exactly. `/rollup` reads the first lines.

```markdown
<!-- rollup-token: TOKEN -->
in_flight: yes|no
in_flight_reasons: <comma list, or none>

# <session title>

- Session: <local_ session id>
- Branch: <branch or none> · PR: <url and state, or none>
- Resources: <count of ledger simulators, worktrees, and DerivedData folders. The archive hook removes them.>

## Done
- ...

## Remaining
- ...

## Next steps
- [user|claude] ...
```

Replace TOKEN with the token from the /rollup request. If no token was given, write `none`.
Get the session title and id with `get_session` and the value "self".
Keep each section short. Write "none" for an empty section.
