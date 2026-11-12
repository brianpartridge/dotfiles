#!/usr/bin/env python3
"""PostToolUse hook. Records resources that a session creates.

The ledger lets cleanup.py remove only items that this session owns.
Ledger: ~/.claude/session-ledgers/<session-id>/ledger.jsonl
This hook never blocks a tool call. It exits 0 on every error.
"""
import json
import os
import re
import shlex
import sys
import time
from pathlib import Path

UUID_RE = re.compile(r"\b[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\b", re.IGNORECASE)


def session_id(payload):
    return os.environ.get("CLAUDE_CODE_HOST_SESSION_ID") or payload.get("session_id") or "unknown"


def ledger_path(sid):
    d = Path.home() / ".claude" / "session-ledgers" / sid
    d.mkdir(parents=True, exist_ok=True)
    return d / "ledger.jsonl"


def record(sid, kind, value, cwd, extra=None):
    entry = {"kind": kind, "value": value, "cwd": cwd, "ts": int(time.time())}
    if extra:
        entry.update(extra)
    with ledger_path(sid).open("a") as f:
        f.write(json.dumps(entry) + "\n")


def tokens_of(command):
    try:
        return shlex.split(command, posix=True)
    except ValueError:
        return command.split()


def split_segments(tokens):
    seg = []
    for t in tokens:
        if t in ("&&", "||", ";", "|"):
            if seg:
                yield seg
            seg = []
        else:
            seg.append(t)
    if seg:
        yield seg


def resolve(path, base):
    p = Path(os.path.expanduser(path))
    if not p.is_absolute():
        p = Path(base) / p
    return str(p.resolve())


def handle_bash(sid, payload):
    cmd = (payload.get("tool_input") or {}).get("command", "")
    cwd = payload.get("cwd") or os.getcwd()
    resp = payload.get("tool_response") or {}
    stdout = resp.get("stdout", "") if isinstance(resp, dict) else str(resp)

    for seg in split_segments(tokens_of(cmd)):
        # Follow "cd <dir>" so that relative paths resolve correctly.
        if seg and seg[0] in ("cd", "pushd"):
            target = seg[1] if len(seg) > 1 else str(Path.home())
            if not target.startswith("$"):
                cwd = resolve(target, cwd)
            continue
        # Simulators: xcrun simctl create|clone prints the new UDID.
        if "simctl" in seg and ("create" in seg or "clone" in seg):
            for udid in UUID_RE.findall(stdout):
                record(sid, "simulator", udid.upper(), cwd)

        # Worktrees: git [-C dir] worktree add [opts] <path> [commit]
        if seg and os.path.basename(seg[0]) == "git" and "worktree" in seg:
            i = seg.index("worktree")
            if i + 1 < len(seg) and seg[i + 1] == "add":
                base = cwd
                if "-C" in seg[:i]:
                    base = resolve(seg[seg.index("-C") + 1], cwd)
                args = seg[i + 2:]
                pos = []
                skip = False
                for a in args:
                    if skip:
                        skip = False
                        continue
                    if a in ("-b", "-B", "--reason"):
                        skip = True
                        continue
                    if a.startswith("-"):
                        continue
                    pos.append(a)
                if pos:
                    record(sid, "worktree", resolve(pos[0], base), cwd, {"repo": base})

        # DerivedData: xcodebuild -derivedDataPath <dir>
        if seg and os.path.basename(seg[0]) == "xcodebuild" and "-derivedDataPath" in seg:
            j = seg.index("-derivedDataPath")
            if j + 1 < len(seg):
                record(sid, "deriveddata", resolve(seg[j + 1], cwd), cwd)


def handle_enter_worktree(sid, payload):
    resp = payload.get("tool_response")
    text = json.dumps(resp) if not isinstance(resp, str) else resp
    m = re.search(r'(/[^"\s]*/worktrees/[^"\s]+)', text)
    if m:
        record(sid, "worktree", m.group(1).rstrip("/."), payload.get("cwd", ""), {"via": "EnterWorktree"})


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:  # noqa: BLE001
        return
    sid = session_id(payload)
    tool = payload.get("tool_name", "")
    if tool == "Bash":
        handle_bash(sid, payload)
    elif tool == "EnterWorktree":
        handle_enter_worktree(sid, payload)


if __name__ == "__main__":
    try:
        main()
    except Exception:  # noqa: BLE001, S110
        pass
    sys.exit(0)
