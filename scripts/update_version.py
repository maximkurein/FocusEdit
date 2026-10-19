#!/usr/bin/env python3
"""Single source of truth for the FocusEdit version.

The marketing version MAJOR.MINOR.PATCH lives in Info.plist
(CFBundleShortVersionString). This script keeps CHANGELOG.md in sync with it and
never touches the build number (CFBundleVersion), which package.sh stamps.

Commands:
    status                 show each file; exit 1 if anything is out of sync
    bump patch|minor|major next version by semver, release date = today
    sync X.Y.Z             set version X.Y.Z, release date = today
    sync                   re-apply the current source version

Flags for bump/sync: --release-date YYYY-MM-DD, --dry-run.
Standard library only; no virtualenv needed.
"""

from __future__ import annotations

import argparse
import datetime as dt
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PLIST = ROOT / "Info.plist"
CHANGELOG = ROOT / "CHANGELOG.md"

PLIST_RE = re.compile(
    r"(<key>CFBundleShortVersionString</key>\s*<string>)([^<]+)(</string>)"
)
RELEASED_RE = re.compile(r"^## \[(\d+\.\d+(?:\.\d+)?)\]\s*-\s*(\d{4}-\d{2}-\d{2})", re.M)


class VersionError(Exception):
    pass


# --- reading -----------------------------------------------------------------

def read_source() -> str:
    text = PLIST.read_text(encoding="utf-8")
    m = PLIST_RE.search(text)
    if not m:
        raise VersionError("CFBundleShortVersionString not found in Info.plist")
    return m.group(2).strip()


def latest_changelog() -> tuple[str, str] | None:
    if not CHANGELOG.exists():
        return None
    m = RELEASED_RE.search(CHANGELOG.read_text(encoding="utf-8"))
    return (m.group(1), m.group(2)) if m else None


def normalize(v: str) -> tuple[int, int, int]:
    parts = [int(p) for p in v.split(".")]
    while len(parts) < 3:
        parts.append(0)
    if len(parts) != 3:
        raise VersionError(f"not a MAJOR.MINOR.PATCH version: {v}")
    return parts[0], parts[1], parts[2]


# --- status ------------------------------------------------------------------

def cmd_status() -> int:
    source = read_source()
    cl = latest_changelog()
    ok = True

    print(f"source     Info.plist     {source}")
    if cl is None:
        print("changelog  CHANGELOG.md    MISSING (no released header)")
        ok = False
    else:
        ver, date = cl
        mark = "OK" if ver == source else "DIFF"
        if ver != source:
            ok = False
        print(f"changelog  CHANGELOG.md    {ver}  ({date})  {mark}")

    print("OK" if ok else "OUT OF SYNC")
    return 0 if ok else 1


# --- writing -----------------------------------------------------------------

def set_plist(text: str, version: str) -> str:
    new, n = PLIST_RE.subn(lambda m: m.group(1) + version + m.group(3), text)
    if n == 0:
        raise VersionError("Could not update Info.plist (pattern changed)")
    return new


def set_changelog(text: str, version: str, date: str) -> str:
    """Rename the [Unreleased] section to [version] - date and add a fresh one."""
    if re.search(rf"^## \[{re.escape(version)}\]", text, re.M):
        return text  # header already present
    if "## [Unreleased]" not in text:
        raise VersionError("Could not update CHANGELOG.md (no [Unreleased] section)")
    replacement = f"## [Unreleased]\n\n## [{version}] - {date}"
    return text.replace("## [Unreleased]", replacement, 1)


def apply(version: str, date: str, dry_run: bool) -> None:
    normalize(version)
    plist_text = PLIST.read_text(encoding="utf-8")
    new_plist = set_plist(plist_text, version)

    changelog_text = CHANGELOG.read_text(encoding="utf-8") if CHANGELOG.exists() else ""
    new_changelog = set_changelog(changelog_text, version, date) if changelog_text else changelog_text

    print(f"Target version:      {version}")
    print(f"Target release date: {date}\n")

    changed = []
    if new_plist != plist_text:
        changed.append((PLIST, new_plist))
    if changelog_text and new_changelog != changelog_text:
        changed.append((CHANGELOG, new_changelog))

    if not changed:
        print("Nothing to update (already in sync).")
        return

    for path, content in changed:
        rel = path.relative_to(ROOT)
        if dry_run:
            print(f"Would update {rel}")
        else:
            path.write_text(content, encoding="utf-8")
            print(f"Updated {rel}")


def cmd_bump(level: str, date: str, dry_run: bool) -> int:
    major, minor, patch = normalize(read_source())
    if level == "patch":
        patch += 1
    elif level == "minor":
        minor, patch = minor + 1, 0
    elif level == "major":
        major, minor, patch = major + 1, 0, 0
    apply(f"{major}.{minor}.{patch}", date, dry_run)
    return 0


def cmd_sync(version: str | None, date: str, dry_run: bool) -> int:
    apply(version or read_source(), date, dry_run)
    return 0


# --- cli ---------------------------------------------------------------------

def main(argv: list[str]) -> int:
    today = dt.date.today().isoformat()
    p = argparse.ArgumentParser(description="FocusEdit version management")
    sub = p.add_subparsers(dest="command", required=True)

    sub.add_parser("status")

    b = sub.add_parser("bump")
    b.add_argument("level", choices=["patch", "minor", "major"])
    b.add_argument("--release-date", default=today)
    b.add_argument("--dry-run", action="store_true")

    s = sub.add_parser("sync")
    s.add_argument("version", nargs="?")
    s.add_argument("--release-date", default=today)
    s.add_argument("--dry-run", action="store_true")

    args = p.parse_args(argv)
    try:
        if args.command == "status":
            return cmd_status()
        if args.command == "bump":
            return cmd_bump(args.level, args.release_date, args.dry_run)
        if args.command == "sync":
            return cmd_sync(args.version, args.release_date, args.dry_run)
    except VersionError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
