#!/usr/bin/env python3
"""settings.py — idempotent merge/unmerge of settings.json fragments.

Used by install.sh and uninstall.sh to add or remove the statusLine block
without clobbering anything else in the user's settings.json.

Subcommands:
  add-statusline    --settings PATH --command CMD [--refresh N] [--force] [--dry-run]
  remove-statusline --settings PATH --command CMD [--dry-run]

Non-destructive guarantees:
  - Refuses to touch malformed JSON.
  - `add` skips if statusLine is already present (exact-match no-op, or
    --force required to overwrite with a backup).
  - `remove` only deletes the statusLine key if its `command` value exactly
    matches what install.sh wrote — a user-modified command is left alone.
  - Every write creates a backup: <settings>.bak-<ts>-<pid>.
"""
import argparse
import datetime
import json
import os
import shutil
import sys


def die(msg, code=1):
    print(f"settings.py: {msg}", file=sys.stderr)
    sys.exit(code)


def load(path):
    if not os.path.exists(path):
        return None
    try:
        with open(path) as f:
            return json.load(f)
    except json.JSONDecodeError as e:
        die(f"refusing to touch malformed JSON at {path}: {e}")


def backup(path):
    ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    dest = f"{path}.bak-{ts}-{os.getpid()}"
    shutil.copy2(path, dest)
    return dest


def save(path, data):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")


def cmd_add_statusline(args):
    entry = {"type": "command", "command": args.command, "refreshInterval": args.refresh}
    data = load(args.settings)
    existed = data is not None
    if data is None:
        data = {}

    if "statusLine" in data:
        if data["statusLine"] == entry:
            print(f"[settings] statusLine already matches in {args.settings}; no-op")
            return
        if not args.force:
            print(f"[settings] skip {args.settings} statusLine (already configured; --force to overwrite)")
            return

    if args.dry_run:
        action = "overwrite" if "statusLine" in data else ("merge into" if existed else "create")
        print(f"[settings][dry-run] would {action} {args.settings} with statusLine = {json.dumps(entry)}")
        return

    if existed:
        backup(args.settings)
    data["statusLine"] = entry
    save(args.settings, data)
    verb = "created" if not existed else "merged into"
    print(f"[settings] {verb} {args.settings}")


def cmd_remove_statusline(args):
    data = load(args.settings)
    if data is None:
        return  # no settings file, nothing to undo
    sl = data.get("statusLine")
    if not isinstance(sl, dict) or sl.get("command") != args.command:
        print(f"[settings] statusLine in {args.settings} is not ours (or absent); leaving alone")
        return
    if args.dry_run:
        print(f"[settings][dry-run] would remove statusLine from {args.settings}")
        return
    backup(args.settings)
    del data["statusLine"]
    save(args.settings, data)
    print(f"[settings] removed statusLine from {args.settings}")


def main():
    p = argparse.ArgumentParser(prog="settings.py", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    subs = p.add_subparsers(dest="cmd", required=True)

    a = subs.add_parser("add-statusline", help="merge a statusLine block into settings.json")
    a.add_argument("--settings", required=True)
    a.add_argument("--command", required=True)
    a.add_argument("--refresh", type=int, default=2)
    a.add_argument("--force", action="store_true")
    a.add_argument("--dry-run", action="store_true")
    a.set_defaults(func=cmd_add_statusline)

    r = subs.add_parser("remove-statusline", help="remove a statusLine block if it matches --command")
    r.add_argument("--settings", required=True)
    r.add_argument("--command", required=True)
    r.add_argument("--dry-run", action="store_true")
    r.set_defaults(func=cmd_remove_statusline)

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
