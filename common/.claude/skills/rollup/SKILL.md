---
name: rollup
description: Roll up the status of all child sessions into this session, depth first. Each child runs /rollup on its own children, then /report, and writes a report. This session aggregates the reports and archives each child that has no in-flight work. Use when the user types /rollup, or when a parent session sends "/rollup token=...".
---

# Rollup

Collect a status report from each child session, depth first. Archive children with no in-flight work.
Then run `/report` on this session and write one aggregated report.

Reports go to `~/.claude/session-ledgers/<session id>/report.md`. The format is in the report skill.

Do not clean up anything. When `archive_session` archives a child, a hook runs the final cleanup for it.
The daily job "Daily dev disk cleanup" also cleans up archived sessions that the hook missed.
See `~/.claude/session-cleanup/README.md`.

## Rules

- Never delete a session. Never merge or push a branch.
- Never archive this session. Only the parent of a session archives it.
- Archive a child only if all checks in step 5 pass.
- A child that does not report stays. Do not guess its state.

## Procedure

### 1. Start

- Get this session with `get_session` and the value "self". Record its `sessionId` as SELF.
- If the request has a token, as in `/rollup token=T`, record T as MY_TOKEN. Else set MY_TOKEN to `none`.
- Make a new token for the children: CHILD_TOKEN = `<SELF>-<unix time>`.

### 2. Find the direct children

- Call `list_sessions` with `{"linked": true}`.
- Keep only sessions with `startedBy` equal to SELF. These are the direct children.
- If there are no children, go to step 6.

### 3. Ask each child for a report

For each child:
- If the child `isRemote` is true, do not message it. Mark it "keep: cloud session, no report".
- Else send it this message with `send_message`:

  ```
  /rollup token=CHILD_TOKEN
  Write your report to ~/.claude/session-ledgers/<your session id>/report.md. Your parent reads it.
  ```

Then end the turn. Say in one line which children you asked. The app continues this session when the children become idle.

### 4. Collect the reports

On each continuation, do these checks again for each child that has no result:
- Read `~/.claude/session-ledgers/<child id>/report.md`.
- If the first line has `rollup-token: CHILD_TOKEN`, the report is fresh. Record it.
- If the report is not fresh, call `list_sessions` with `{"linked": true}`.
  - If the child or a session below it still runs, wait. End the turn.
  - If nothing below the child runs, mark it "keep: no report".

When each child has a fresh report or a "keep" mark, go to step 5.
If the app stops sending continuations, tell the user. Ask the user to run /rollup again.

### 5. Decide and archive

For each child with a fresh report, check all of these:
- The report says `in_flight: no`.
- `get_session` for the child shows `isRunning` false.
- `list_sessions` shows no session below the child that is not archived.
- The independent git check shows no in-flight work. Run it with the child's `cwd`. It is a dry run and changes nothing:
  ```bash
  python3 -I ~/.claude/session-cleanup/cleanup.py --session <child id> --cwd "<child cwd>" --no-orphans
  ```
  The check fails if `git.uncommitted_files` is more than 0.
  It fails if `git.unpushed_commits` is more than 0, or if there is no upstream and the branch is not merged.
  It fails if `pr.state` is `OPEN`.

If all checks pass:
1. Call `archive_session` for the child. Give a short reason, for example "rollup: no in-flight work".
2. If the archive call fails, mark the child "keep" with the error.

If one check fails, mark the child "keep" with the failed check as the reason.

### 6. Report on this session

Follow the report skill for this session, with MY_TOKEN as the token.
Set `in_flight: yes` if one or more children have a "keep" mark. Add "child sessions kept" to the reasons.

### 7. Aggregate

Add this section to the end of this session's report.md, before the reply:

```markdown
## Children

### Archived
- <title> (<id>): <one-line summary of what it did>

### Kept
- <title> (<id>): <reason>
  - Remaining: <from its report>
  - Next steps: <from its report>
```

Copy the "Remaining" and "Next steps" of each kept child. Keep grandchildren that the child kept, one level indented.
Post the full report as the reply. Link each session as [title](#<session id>).

## Limits

- The app can hold continuations after many automated turns in a row. A deep tree can stop. Run /rollup again to continue. Fresh reports stay valid only for the token of the run that asked for them.
- Cloud sessions do not report. They always stay.
- `archive_session` can ask the user for approval, and it does not archive a session that is pinned or open on screen.
