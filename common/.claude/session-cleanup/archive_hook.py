#!/usr/bin/env python3
"""Run the final cleanup for a session when the session is archived.

Two hook events call this script:
  SessionEnd                         the session's own process ends. The script
                                     cleans up only if the app marks the session
                                     archived. Other ends (app quit, idle stop,
                                     /clear) do nothing.
  PostToolUse archive_session        another session archived a session. The
                                     script cleans up the target session.

The cleanup is `cleanup.py --session <id> --cwd <dir> --apply --final`.
It runs detached, so the hook returns at once. Output goes to
~/.claude/session-ledgers/<id>/archive-cleanup.json.
Each call adds one line to ~/.claude/session-ledgers/archive-hook.log.
The script reads the app's session record. It never writes to it.
This hook never blocks. It exits 0 on every error.
"""
import glob
import json
import os
import subprocess
import sys
import time
from pathlib import Path

HOME = Path.home()
RECORDS = HOME / "Library/Application Support/Claude/claude-code-sessions"
LEDGERS = HOME / ".claude" / "session-ledgers"
CLEANUP = HOME / ".claude/session-cleanup/cleanup.py"


def log(msg):
    LEDGERS.mkdir(parents=True, exist_ok=True)
    with (LEDGERS / "archive-hook.log").open("a") as f:
        f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S%z')} {msg}\n")


def record(sid):
    for p in glob.glob(str(RECORDS / "*" / "*" / f"{sid}.json")):
        try:
            return json.loads(Path(p).read_text())
        except Exception:  # noqa: BLE001
            return None
    return None


def wait_archived(sid, seconds):
    """The app can write isArchived after it stops the process. Poll briefly."""
    end = time.time() + seconds
    rec = record(sid)
    while rec is not None and not rec.get("isArchived") and time.time() < end:
        time.sleep(0.5)
        rec = record(sid)
    return rec


def start_cleanup(sid, cwd):
    out = LEDGERS / sid
    out.mkdir(parents=True, exist_ok=True)
    with (out / "archive-cleanup.json").open("w") as f:
        subprocess.Popen(
            ["python3", "-I", str(CLEANUP), "--session", sid, "--cwd", cwd or str(HOME),
             "--apply", "--final"],
            stdout=f, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
            cwd=str(HOME), start_new_session=True,
        )


def main():
    payload = json.load(sys.stdin)
    event = payload.get("hook_event_name", "")
    if event == "SessionEnd":
        sid = os.environ.get("CLAUDE_CODE_HOST_SESSION_ID")
        if not sid:
            log(f"SessionEnd reason={payload.get('reason')} no host session id, skip")
            return
        rec = wait_archived(sid, 5)
        archived = bool(rec and rec.get("isArchived"))
        log(f"SessionEnd {sid} reason={payload.get('reason')} archived={archived}")
        if archived:
            start_cleanup(sid, rec.get("worktreePath") or rec.get("cwd") or payload.get("cwd"))
    elif event == "PostToolUse":
        sid = (payload.get("tool_input") or {}).get("session_id", "")
        if not sid or sid == "self":
            return  # "self" ends this session; SessionEnd handles it.
        rec = wait_archived(sid, 3)
        archived = bool(rec and rec.get("isArchived"))
        log(f"archive_session {sid} archived={archived}")
        if archived:
            start_cleanup(sid, rec.get("worktreePath") or rec.get("cwd"))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # noqa: BLE001
        try:
            log(f"error {e!r}")
        except Exception:  # noqa: BLE001, S110
            pass
    sys.exit(0)
