#!/usr/bin/env python3
"""Report on or clean up the resources that one Claude session owns.

Usage:
  session-resources.py report                 read-only. Prints the git and PR state, the
                                              ledger, and the actions a cleanup would take.
  session-resources.py report --final         the same, for a session that is about to end.
  session-resources.py cleanup                removes the items. Add --dry-run to change nothing.
  session-resources.py cleanup --final        the session is about to end. Also delete its ledger
                                              DerivedData and shut down and delete its booted simulators.
  session-resources.py cleanup --sweep        machine-wide sweep for the daily job. See sweep().
  --session <id> --cwd <dir>                  act for a different session. report and cleanup only.

Rules:
  - Simulators: delete ledger simulators that are shut down. Delete "unavailable" simulators.
    If the simulator list fails, stop before any change, so a later run can retry.
  - Worktrees: remove ledger worktrees only if clean, fully pushed or merged, and not the cwd.
  - DerivedData: delete default DerivedData whose project no longer exists, or whose
    project is in a ledger worktree that this run removed. With --final, also delete
    ledger DerivedData folders that pass is_unsafe_dd(). The session cwd's default
    DerivedData is never deleted here: another session can share the cwd. The sweep
    handles it. report does not look for orphan DerivedData.
  - Never delete branches, sessions, or anything outside these rules.
  - cleanup holds a per-session lock, so runs for the same session do not overlap.

Output: "pr" is null when the branch has no PR, and {"state": "UNKNOWN", ...} when
the PR lookup failed. "worktrees" has the git and PR state of each ledger worktree.
"""
import argparse
import fcntl
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


def save_ledger(path, entries, loaded):
    """Write entries, plus any records that ledger_hook appended after the load.

    ledger_hook appends under the same short "ledger.lock", so no append is lost.
    The lock is held only for the read and the write, not during deletions.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    with (path.parent / "ledger.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        current = load_ledger(path)
        appended = [e for e in current if e not in loaded]
        tmp = path.with_suffix(".tmp")
        tmp.write_text("".join(json.dumps(e) + "\n" for e in entries + appended))
        tmp.replace(path)


def remove_tree(path):
    """Delete a folder. Return None on success, or an error message when it still exists."""
    errors = []
    # onerror, not onexc: the system python3 is 3.9.
    shutil.rmtree(path, onerror=lambda _f, p, ei: errors.append(f"{p}: {ei[1]}"))
    if Path(path).exists():
        return (errors[0] if errors else "folder still exists")[:200]
    return None


def git_status(path):
    """Return a dict with the git state of a checkout, or None if it is not a repo.

    When a query fails, its field is None and "error" names the failure. A caller
    must treat a non-null "error" as unverified state, not as clean.
    """
    code, top, _ = run(["git", "-C", str(path), "rev-parse", "--show-toplevel"])
    if code != 0:
        return None
    errors = []
    _, branch, _ = run(["git", "-C", str(path), "rev-parse", "--abbrev-ref", "HEAD"])
    code, porcelain, err = run(["git", "-C", str(path), "status", "--porcelain"], timeout=120)
    if code == 0:
        dirty = len([l for l in porcelain.splitlines() if l.strip()])
    else:
        dirty = None
        errors.append(f"git status failed: {err[:120]}")
    code, upstream, _ = run(["git", "-C", str(path), "rev-parse", "--abbrev-ref", "@{upstream}"])
    upstream = upstream if code == 0 else None
    ahead = None
    if upstream:
        code, n, err = run(["git", "-C", str(path), "rev-list", "--count", "@{upstream}..HEAD"])
        if code == 0 and n.isdigit():
            ahead = int(n)
        else:
            errors.append(f"ahead count failed: {err[:120]}")
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
        "error": "; ".join(errors) or None,
    }


def pr_status(path):
    """Return the PR, None when the branch has no PR, or an UNKNOWN state when the lookup failed."""
    if not shutil.which("gh"):
        return {"state": "UNKNOWN", "error": "gh is not installed"}
    code, out, err = run(["gh", "pr", "view", "--json", "number,url,state,isDraft,title"], cwd=str(path), timeout=30)
    if code == 0 and out:
        try:
            return json.loads(out)
        except json.JSONDecodeError:
            return {"state": "UNKNOWN", "error": "gh printed invalid JSON"}
    if "no pull requests found" in err.lower():
        return None
    return {"state": "UNKNOWN", "error": (err or f"gh exit {code}")[:200]}


def simulators():
    """Return the devices by UDID, or None when the list command fails."""
    code, out, _ = run(["xcrun", "simctl", "list", "devices", "-j"])
    if code != 0:
        return None
    try:
        data = json.loads(out).get("devices", {})
    except (json.JSONDecodeError, AttributeError):
        return None
    devs = {}
    for runtime, items in data.items():
        for d in items:
            devs[d["udid"].upper()] = {**d, "runtime": runtime}
    return devs


def delete_unavailable(sims, apply):
    """Delete "unavailable" simulators. Return the action, an error action, or None."""
    unavailable = [d for d in sims.values() if not d.get("isAvailable", True)]
    if not unavailable:
        return None
    target = f"{len(unavailable)} unavailable"
    if apply:
        code, _, err = run(["xcrun", "simctl", "delete", "unavailable"])
        if code != 0:
            return {"kind": "simulator", "target": target, "action": "error",
                    "reason": (err or f"simctl exit {code}")[:200]}
    return {"kind": "simulator", "target": target, "action": "delete"}


DD_MARKERS = ("Build", "Logs", "Index.noindex", "ModuleCache.noindex", "SourcePackages", "info.plist")
PROJECT_MARKERS = ("Package.swift", ".git")


def is_unsafe_dd(path, protected):
    """Return a reason when a recorded DerivedData path must not be deleted, else None.

    A -derivedDataPath of "." or ".." records the checkout itself. So reject home,
    "/", any protected folder (session cwd, recorded command cwd, repo) and its
    ancestors, any git checkout root, and any folder that holds a project. Also
    require at least one Xcode build-output marker.
    """
    p = path.resolve()
    if p == HOME or p in HOME.parents:
        return "home or one of its parents"
    for q in protected:
        if p == q or p in q.parents:
            return f"is or contains {q}"
    for m in PROJECT_MARKERS:
        if (p / m).exists():
            return f"holds {m}"
    if any(p.glob("*.xcodeproj")) or any(p.glob("*.xcworkspace")):
        return "holds an Xcode project"
    if not any((p / m).exists() for m in DD_MARKERS):
        return "no Xcode build-output marker"
    return None


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
                err = remove_tree(d)
                if err:
                    actions.append({"kind": "deriveddata", "target": d.name, "action": "error", "reason": err})
                    continue
            freed += size
            actions.append({"kind": "deriveddata", "target": d.name, "action": "delete", "bytes": size, "reason": reason})

    sims = simulators()
    if sims is None:
        actions.append({"kind": "simulator", "target": "all", "action": "error",
                        "reason": "simctl list failed, simulators skipped"})
        sims = {}
    action = delete_unavailable(sims, apply)
    if action:
        actions.append(action)

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


def parse_args(argv=None):
    ap = argparse.ArgumentParser(description="Report on or clean up the resources of a Claude session.")
    sub = ap.add_subparsers(dest="action", required=True)

    def session_args(p):
        p.add_argument("--session", default=os.environ.get("CLAUDE_CODE_HOST_SESSION_ID") or "unknown")
        p.add_argument("--cwd", default=os.getcwd())
        p.add_argument("--final", action="store_true", help="the session is about to end")

    rp = sub.add_parser("report", help="read-only status: git, PR, ledger, and planned actions")
    session_args(rp)

    cp = sub.add_parser("cleanup", help="remove the resources that the session or the machine no longer needs")
    session_args(cp)
    cp.add_argument("--dry-run", action="store_true", help="show the actions, change nothing")
    cp.add_argument("--no-orphans", action="store_true", help="skip orphaned DerivedData")
    cp.add_argument("--sweep", action="store_true",
                    help="machine-wide sweep of stale DerivedData and session simulators; ignores the ledger")
    cp.add_argument("--stale-days", type=int, default=14, help="--sweep: worktree DerivedData age limit")
    cp.add_argument("--sim-stale-days", type=int, default=7, help="--sweep: session simulator age limit")
    args = ap.parse_args(argv)
    args.apply = args.action == "cleanup" and not args.dry_run
    args.orphans = args.action == "cleanup" and not args.no_orphans
    return args


def main():
    args = parse_args()

    if args.action == "cleanup" and args.sweep:
        sweep(args.apply, args.stale_days, args.sim_stale_days)
        return

    cwd = Path(args.cwd).resolve()
    ledger_file = HOME / ".claude" / "session-ledgers" / args.session / "ledger.jsonl"
    if args.apply:
        # Two hooks can see the same archive. Hold the lock through load, removal, and save.
        ledger_file.parent.mkdir(parents=True, exist_ok=True)
        lock = (ledger_file.parent / ".lock").open("w")
        fcntl.flock(lock, fcntl.LOCK_EX)
    entries = load_ledger(ledger_file)
    keep = []
    actions = []  # each: {kind, target, action, reason, bytes}
    freed = 0

    # --- Simulators ---------------------------------------------------------
    sims = simulators()
    if sims is None:
        if any(e.get("kind") == "simulator" for e in entries):
            json.dump({"session": args.session, "error": "simctl list failed. Nothing changed. Run again later.",
                       "ledger_remaining": entries}, sys.stdout, indent=2)
            print()
            sys.exit(2)
        sims = {}
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

    action = delete_unavailable(sims, args.apply)
    if action:
        actions.append(action)

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
        if not st:
            reasons.append("not a git checkout")
        elif st.get("error"):
            reasons.append(f"git state unverified: {st['error']}")
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
        protected = {cwd}
        for key in ("cwd", "repo"):
            if e.get(key):
                protected.add(Path(e[key]).resolve())
        unsafe = is_unsafe_dd(p, protected)
        if unsafe:
            actions.append({"kind": "deriveddata", "target": str(p), "action": "keep", "reason": f"unsafe: {unsafe}"})
            keep.append(e)
            continue
        size = du(p)
        if args.apply:
            err = remove_tree(p)
            if err:
                # Keep the entry so a later cleanup can retry.
                actions.append({"kind": "deriveddata", "target": str(p), "action": "error", "reason": err})
                keep.append(e)
                continue
        freed += size
        actions.append({"kind": "deriveddata", "target": str(p), "action": "delete", "bytes": size})

    if args.orphans and DD_ROOT.exists():
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
            # Not the session cwd: another session can share it. The sweep handles it.
            in_removed = any(ws.startswith(w.rstrip("/") + "/") for w in removed_worktrees)
            if not (gone or in_removed):
                continue
            # A project on an unmounted volume looks gone. Skip /Volumes paths.
            if ws.startswith("/Volumes/") and gone and not in_removed:
                continue
            size = du(d)
            if args.apply:
                err = remove_tree(d)
                if err:
                    actions.append({"kind": "deriveddata", "target": d.name, "action": "error", "reason": err})
                    continue
            freed += size
            actions.append({"kind": "deriveddata", "target": d.name, "action": "delete", "bytes": size,
                            "reason": f"project gone: {ws}" if gone else f"worktree ended: {ws}"})

    if args.apply:
        save_ledger(ledger_file, keep, entries)

    # --- Status -------------------------------------------------------------
    status = git_status(cwd)
    remaining = keep if args.apply else list(entries)
    worktrees = []
    for e in remaining:
        if e.get("kind") != "worktree" or not Path(e["value"]).exists():
            continue
        wst = git_status(e["value"])
        worktrees.append({"path": e["value"], "git": wst, "pr": pr_status(e["value"]) if wst else None})
    report = {
        "session": args.session,
        "cwd": str(cwd),
        "time": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "mode": args.action + ("" if args.apply or args.action == "report" else " dry-run") + (" final" if args.final else ""),
        "git": status,
        "pr": pr_status(cwd) if status else None,
        "worktrees": worktrees,
        "ledger_remaining": remaining,
        "actions": actions,
        "freed_bytes": freed,
        "freed": human(freed),
    }
    json.dump(report, sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    main()
