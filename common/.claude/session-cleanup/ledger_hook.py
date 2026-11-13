#!/usr/bin/env python3
"""PostToolUse hook. Records resources that a session creates.

The ledger lets session-resources.py remove only items that this session owns.
Ledger: ~/.claude/session-ledgers/<session-id>/ledger.jsonl
This hook never blocks a tool call. It exits 0 on every error.
"""
import fcntl
import json
import os
import re
import shlex
import sys
import time
from pathlib import Path

UUID_LINE_RE = re.compile(r"[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}", re.IGNORECASE)
SEPARATORS = {"&&", "||", ";", ";;", "|", "&", "(", ")", "\n"}


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
    path = ledger_path(sid)
    # session-resources.py rewrites the ledger under the same short lock, so no append is lost.
    with (path.parent / "ledger.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        with path.open("a") as f:
            f.write(json.dumps(entry) + "\n")


def mark_newlines(command):
    """Replace each unquoted newline with a " \\n " token, so it splits segments like ";"."""
    out, quote, esc = [], None, False
    for ch in command:
        if esc:
            esc = False
        elif ch == "\\" and quote != "'":
            esc = True
        elif quote:
            if ch == quote:
                quote = None
        elif ch in ("'", '"'):
            quote = ch
        elif ch == "\n":
            out.append(" ; ")
            continue
        out.append(ch)
    return "".join(out)


def tokens_of(command):
    """Split a command into words. Unquoted ; & | ( ) and newlines become their own tokens."""
    try:
        lex = shlex.shlex(mark_newlines(command), posix=True, punctuation_chars=";&|()")
        lex.whitespace_split = True
        return list(lex)
    except ValueError:
        return command.split()


def split_segments(tokens):
    seg = []
    for t in tokens:
        if t in SEPARATORS:
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


# A Bash call runs for 10 minutes at most. A folder that this call created has a
# birth time inside that window. An older folder belongs to someone else.
MAX_CALL_SECONDS = 660


def created_by_this_call(path):
    """True if the folder exists and was born during this Bash call."""
    try:
        st = os.stat(path)
    except OSError:
        return False
    born = getattr(st, "st_birthtime", st.st_ctime)
    return time.time() - born <= MAX_CALL_SECONDS


def is_conditional(cmd):
    """Commands with || or if/then can skip a segment, so execution is not known."""
    return "||" in cmd or re.search(r"(^|[;&\s])(if|then|else|elif)\s", cmd) is not None


def handle_bash(sid, payload):
    cmd = (payload.get("tool_input") or {}).get("command", "")
    cwd = payload.get("cwd") or os.getcwd()
    resp = payload.get("tool_response") or {}
    stdout = resp.get("stdout", "") if isinstance(resp, dict) else str(resp)
    if is_conditional(cmd) or (isinstance(resp, dict) and resp.get("interrupted")):
        return

    segments = list(split_segments(tokens_of(cmd)))
    creates = [s for s in segments if "simctl" in s and ("create" in s or "clone" in s)]
    # simctl create|clone prints the new UDID alone on one line. Other commands in the
    # same Bash call (for example "simctl list") can print other UDIDs. Record a UDID
    # only when there is one create or clone and exactly one bare-UDID line.
    created_udid = None
    if len(creates) == 1:
        bare = [ln.strip() for ln in stdout.splitlines() if UUID_LINE_RE.fullmatch(ln.strip())]
        if len(bare) == 1:
            created_udid = bare[0].upper()

    for seg in segments:
        # Follow "cd <dir>" so that relative paths resolve correctly.
        if seg and seg[0] in ("cd", "pushd"):
            target = seg[1] if len(seg) > 1 else str(Path.home())
            if not target.startswith("$"):
                cwd = resolve(target, cwd)
            continue
        if seg in creates and created_udid:
            record(sid, "simulator", created_udid, cwd)

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
                    wt = resolve(pos[0], base)
                    # Record only a new worktree: a .git file and a birth time in this call.
                    if Path(wt, ".git").is_file() and created_by_this_call(wt):
                        record(sid, "worktree", wt, cwd, {"repo": base})

        # DerivedData: xcodebuild -derivedDataPath <dir>
        if seg and os.path.basename(seg[0]) == "xcodebuild" and "-derivedDataPath" in seg:
            j = seg.index("-derivedDataPath")
            if j + 1 < len(seg):
                dd = resolve(seg[j + 1], cwd)
                # A folder that existed before this call belongs to someone else.
                # Never claim the cwd, its parents, or a checkout ("." or "..").
                is_checkout = dd == cwd or cwd.startswith(dd.rstrip("/") + "/") or Path(dd, ".git").exists()
                if created_by_this_call(dd) and not is_checkout:
                    record(sid, "deriveddata", dd, cwd)


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
