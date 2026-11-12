#!/usr/bin/env python3
"""Clean up resources that one Claude session owns, then print a JSON status.

Usage:
  cleanup.py            dry run. Shows what it would remove.
  cleanup.py --apply    removes the items.
  cleanup.py --session <id> --cwd <dir>   act for a different session.
  cleanup.py --final    the session is about to end. Also delete its DerivedData
                        and shut down and delete its booted simulators.
  cleanup.py --sweep [--apply]   machine-wide sweep for the daily job. See sweep().

Rules:
  - Simulators: delete ledger simulators that are shut down. Delete "unavailable" simulators.
  - Worktrees: remove ledger worktrees only if clean, fully pushed or merged, and not the cwd.
  - DerivedData: delete default DerivedData whose project no longer exists.
    With --final, also delete ledger DerivedData and DerivedData for the session cwd.
  - Never delete branches, sessions, or anything outside these rules.
"""
import argparse
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

HOME = Path.home()
DD_ROOT = HOME / "Library" / "Developer" / "Xcode" / "DerivedData"


def run(cmd, cwd=None, timeout=60):
    try:
        p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout, check=False)
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except Exception as e:  # noqa: BLE001
        return 1, "", str(e)


def du(path):
    code, out, _ = run(["du", "-sk", str(path)], timeout=300)
    try:
        return int(out.split()[0]) * 1024 if code == 0 else 0
    except (ValueError, IndexError):
        return 0


def human(n):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024:
            return f"{n:.0f}{unit}"
        n /= 1024
    return f"{n:.1f}PB"


def load_ledger(path):
    entries = []
    if path.exists():
        for line in path.read_text().splitlines():
            try:
                entries.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return entries


def save_ledger(path, entries):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text("".join(json.dumps(e) + "\n" for e in entries))
    tmp.replace(path)


def git_status(path):
    """Return a dict with the git state of a checkout, or None if it is not a repo."""
    code, top, _ = run(["git", "-C", str(path), "rev-parse", "--show-toplevel"])
    if code != 0:
        return None
    _, branch, _ = run(["git", "-C", str(path), "rev-parse", "--abbrev-ref", "HEAD"])
    _, porcelain, _ = run(["git", "-C", str(path), "status", "--porcelain"])
    dirty = len([l for l in porcelain.splitlines() if l.strip()])
    code, upstream, _ = run(["git", "-C", str(path), "rev-parse", "--abbrev-ref", "@{upstream}"])
    upstream = upstream if code == 0 else None
    ahead = None
    if upstream:
        _, n, _ = run(["git", "-C", str(path), "rev-list", "--count", "@{upstream}..HEAD"])
        ahead = int(n) if n.isdigit() else None
    merged = False
    code, default, _ = run(["git", "-C", str(path), "symbolic-ref", "--short", "refs/remotes/origin/HEAD"])
    if code == 0 and default:
        c, _, _ = run(["git", "-C", str(path), "merge-base", "--is-ancestor", "HEAD", default])
        merged = c == 0
    return {
        "toplevel": top,
        "branch": branch,
        "uncommitted_files": dirty,
        "upstream": upstream,
        "unpushed_commits": ahead,
        "merged_into_default": merged,
    }


def pr_status(path):
    if not shutil.which("gh"):
        return None
    code, out, _ = run(["gh", "pr", "view", "--json", "number,url,state,isDraft,title"], cwd=str(path), timeout=30)
    if code != 0 or not out:
        return None
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return None


def simulators():
    code, out, _ = run(["xcrun", "simctl", "list", "devices", "-j"])
    if code != 0:
        return {}
    devs = {}
    for runtime, items in json.loads(out).get("devices", {}).items():
        for d in items:
            devs[d["udid"].upper()] = {**d, "runtime": runtime}
    return devs


STOCK_SIM_PREFIXES = ("iPhone", "iPad", "Apple TV", "Apple Watch", "Apple Vision")
SIM_SUFFIX_RE = re.compile(r"-(\d+-\d+-)?(iPhone|iPad|Apple).*$")


def all_ledger_udids():
    udids = set()
    root = HOME / ".claude" / "session-ledgers"
    for f in root.glob("*/ledger.jsonl") if root.exists() else []:
        for e in load_ledger(f):
            if e.get("kind") == "simulator":
                udids.add(str(e.get("value", "")).upper())
    return udids


def live_worktree_names():
    names = []
    for base in list((HOME / "Development").glob("*")) + list(HOME.glob("*")):
        wt = base / ".claude" / "worktrees"
        if wt.is_dir():
            names += [p.name for p in wt.iterdir() if p.is_dir()]
    return names


def sweep(apply, stale_days, sim_stale_days):
    """Machine-wide sweep of items that no live session can still need.

    - DerivedData whose project is gone, or whose project is in a
      */.claude/worktrees/* folder that Xcode has not used for stale_days.
      Folders used in the last day, shared caches, and folders without
      info.plist are kept. /Volumes projects that look gone are kept.
    - "unavailable" simulators.
    - Shut-down simulators with a session-style name (not a stock Apple
      device name) when no live worktree name starts with the name prefix,
      the device folder has not changed for sim_stale_days, and no session
      ledger owns the simulator. Ledger simulators are left to their session.
    """
    now = time.time()
    actions, freed = [], 0

    if DD_ROOT.exists():
        for d in sorted(DD_ROOT.iterdir()):
            info = d / "info.plist"
            if not info.exists():
                continue
            try:
                pl = plistlib.loads(info.read_bytes())
            except Exception:  # noqa: BLE001, S112
                continue
            ws = pl.get("WorkspacePath")
            if not ws:
                continue
            last = pl.get("LastAccessedDate")
            last_s = last.timestamp() if hasattr(last, "timestamp") else info.stat().st_mtime
            age = (now - last_s) / 86400
            if age < 1:
                continue
            gone = not Path(ws).exists()
            if gone and ws.startswith("/Volumes/"):
                continue
            if gone:
                reason = f"project gone: {ws}"
            elif "/.claude/worktrees/" in ws and age >= stale_days:
                reason = f"worktree unused {age:.0f}d: {ws}"
            else:
                continue
            size = du(d)
            if apply:
                shutil.rmtree(d, ignore_errors=True)
            freed += size
            actions.append({"kind": "deriveddata", "target": d.name, "action": "delete", "bytes": size, "reason": reason})

    sims = simulators()
    unavailable = [x for x in sims.values() if not x.get("isAvailable", True)]
    if unavailable:
        if apply:
            run(["xcrun", "simctl", "delete", "unavailable"])
        actions.append({"kind": "simulator", "target": f"{len(unavailable)} unavailable", "action": "delete"})

    owned = all_ledger_udids()
    live = live_worktree_names()
    dev_root = HOME / "Library/Developer/CoreSimulator/Devices"
    for udid, x in sims.items():
        name = x.get("name", "")
        if not x.get("isAvailable", True) or x.get("state") != "Shutdown":
            continue
        if name.startswith(STOCK_SIM_PREFIXES) or udid in owned:
            continue
        prefix = SIM_SUFFIX_RE.sub("", name)
        if not prefix or prefix == name or any(n.startswith(prefix) for n in live):
            continue
        dev = dev_root / udid
        # Child folders change even while shut down, so use the device folder itself.
        if not dev.is_dir() or (now - dev.stat().st_mtime) / 86400 < sim_stale_days:
            continue
        size = du(dev)
        if apply:
            code, _, err = run(["xcrun", "simctl", "delete", udid])
            if code != 0:
                actions.append({"kind": "simulator", "target": f"{name} {udid}", "action": "error", "reason": err})
                continue
        freed += size
        actions.append({"kind": "simulator", "target": f"{name} {udid}", "action": "delete", "bytes": size,
                        "reason": f"no live worktree '{prefix}*'"})

    _, df, _ = run(["df", "-k", str(HOME)])
    try:
        free = int(df.splitlines()[1].split()[3]) * 1024
    except (IndexError, ValueError):
        free = 0
    json.dump({"mode": "sweep " + ("apply" if apply else "dry-run"),
               "time": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
               "actions": actions, "freed_bytes": freed, "freed": human(freed),
               "disk_free": human(free)}, sys.stdout, indent=2)
    print()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sweep", action="store_true",
                    help="machine-wide sweep of stale DerivedData and session simulators; ignores the ledger")
    ap.add_argument("--stale-days", type=int, default=14, help="--sweep: worktree DerivedData age limit")
    ap.add_argument("--sim-stale-days", type=int, default=7, help="--sweep: session simulator age limit")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--session", default=os.environ.get("CLAUDE_CODE_HOST_SESSION_ID") or "unknown")
    ap.add_argument("--cwd", default=os.getcwd())
    ap.add_argument("--final", action="store_true")
    ap.add_argument("--no-orphans", action="store_true", help="skip orphaned DerivedData sweep")
    args = ap.parse_args()

    if args.sweep:
        sweep(args.apply, args.stale_days, args.sim_stale_days)
        return

    cwd = Path(args.cwd).resolve()
    ledger_file = HOME / ".claude" / "session-ledgers" / args.session / "ledger.jsonl"
    entries = load_ledger(ledger_file)
    keep = []
    actions = []  # each: {kind, target, action, reason, bytes}
    freed = 0

    # --- Simulators ---------------------------------------------------------
    sims = simulators()
    for e in entries:
        if e.get("kind") != "simulator":
            continue
        udid = e["value"]
        dev = sims.get(udid)
        if dev is None:
            actions.append({"kind": "simulator", "target": udid, "action": "forget", "reason": "already gone"})
            continue
        if dev.get("state") != "Shutdown" and args.final and args.apply:
            run(["xcrun", "simctl", "shutdown", udid])
        elif dev.get("state") != "Shutdown" and not args.final:
            actions.append({"kind": "simulator", "target": f"{dev['name']} {udid}", "action": "keep", "reason": f"state {dev.get('state')}"})
            keep.append(e)
            continue
        size = du(HOME / "Library/Developer/CoreSimulator/Devices" / udid)
        if args.apply:
            code, _, err = run(["xcrun", "simctl", "delete", udid])
            if code != 0:
                actions.append({"kind": "simulator", "target": udid, "action": "error", "reason": err})
                keep.append(e)
                continue
        freed += size
        actions.append({"kind": "simulator", "target": f"{dev['name']} {udid}", "action": "delete", "bytes": size})

    unavailable = [d for d in sims.values() if not d.get("isAvailable", True)]
    if unavailable:
        if args.apply:
            run(["xcrun", "simctl", "delete", "unavailable"])
        actions.append({"kind": "simulator", "target": f"{len(unavailable)} unavailable", "action": "delete"})

    # --- Worktrees ----------------------------------------------------------
    removed_worktrees = []
    for e in entries:
        if e.get("kind") != "worktree":
            continue
        wt = Path(e["value"])
        if not wt.exists():
            removed_worktrees.append(str(wt))
            actions.append({"kind": "worktree", "target": str(wt), "action": "forget", "reason": "already gone"})
            continue
        if cwd == wt or wt in cwd.parents:
            actions.append({"kind": "worktree", "target": str(wt), "action": "keep", "reason": "session cwd"})
            keep.append(e)
            continue
        st = git_status(wt) or {}
        reasons = []
        if st.get("uncommitted_files"):
            reasons.append(f"{st['uncommitted_files']} uncommitted files")
        pushed = st.get("upstream") and st.get("unpushed_commits") == 0
        if not pushed and not st.get("merged_into_default"):
            reasons.append("commits not pushed or merged")
        if reasons:
            actions.append({"kind": "worktree", "target": str(wt), "action": "keep", "reason": ", ".join(reasons)})
            keep.append(e)
            continue
        size = du(wt)
        if args.apply:
            repo = e.get("repo") or str(wt)
            code, _, err = run(["git", "-C", repo, "worktree", "remove", str(wt)])
            if code != 0:
                actions.append({"kind": "worktree", "target": str(wt), "action": "error", "reason": err})
                keep.append(e)
                continue
        freed += size
        removed_worktrees.append(str(wt))
        actions.append({"kind": "worktree", "target": str(wt), "action": "remove", "bytes": size, "branch": st.get("branch")})

    # --- DerivedData --------------------------------------------------------
    for e in entries:
        if e.get("kind") != "deriveddata":
            continue
        p = Path(e["value"])
        if not p.exists():
            actions.append({"kind": "deriveddata", "target": str(p), "action": "forget", "reason": "already gone"})
            continue
        if not args.final:
            actions.append({"kind": "deriveddata", "target": str(p), "action": "keep", "reason": "session still active"})
            keep.append(e)
            continue
        size = du(p)
        if args.apply:
            shutil.rmtree(p, ignore_errors=True)
        freed += size
        actions.append({"kind": "deriveddata", "target": str(p), "action": "delete", "bytes": size})

    if not args.no_orphans and DD_ROOT.exists():
        for d in sorted(DD_ROOT.iterdir()):
            info = d / "info.plist"
            if not info.exists():
                continue
            try:
                ws = plistlib.loads(info.read_bytes()).get("WorkspacePath")
            except Exception:  # noqa: BLE001, S112
                continue
            if not ws:
                continue
            gone = not Path(ws).exists()
            ended = removed_worktrees + ([str(cwd)] if args.final else [])
            in_removed = any(ws.startswith(w.rstrip("/") + "/") for w in ended)
            if not (gone or in_removed):
                continue
            # A project on an unmounted volume looks gone. Skip /Volumes paths.
            if ws.startswith("/Volumes/") and gone and not in_removed:
                continue
            size = du(d)
            if args.apply:
                shutil.rmtree(d, ignore_errors=True)
            freed += size
            actions.append({"kind": "deriveddata", "target": d.name, "action": "delete", "bytes": size,
                            "reason": f"project gone: {ws}" if gone else f"worktree ended: {ws}"})

    if args.apply:
        save_ledger(ledger_file, keep)

    # --- Status -------------------------------------------------------------
    status = git_status(cwd)
    report = {
        "session": args.session,
        "cwd": str(cwd),
        "time": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "mode": ("apply" if args.apply else "dry-run") + (" final" if args.final else ""),
        "git": status,
        "pr": pr_status(cwd) if status else None,
        "ledger_remaining": keep if args.apply else [e for e in entries],
        "actions": actions,
        "freed_bytes": freed,
        "freed": human(freed),
    }
    json.dump(report, sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    main()
