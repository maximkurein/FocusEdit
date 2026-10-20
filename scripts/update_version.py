#!/usr/bin/env python3
"""Single source of truth for the FocusEdit version.

The marketing version MAJOR.MINOR.PATCH lives in Info.plist
(CFBundleShortVersionString). This script keeps CHANGELOG.md, the README
**Version:** line and the Windows port (windows/package.json, package-lock.json,
src-tauri/tauri.conf.json, Cargo.toml, Cargo.lock) in sync with it and
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
README = ROOT / "README.md"
WIN = ROOT / "windows"

PLIST_RE = re.compile(
    r"(<key>CFBundleShortVersionString</key>\s*<string>)([^<]+)(</string>)"
)
RELEASED_RE = re.compile(r"^## \[(\d+\.\d+(?:\.\d+)?)\]\s*-\s*(\d{4}-\d{2}-\d{2})", re.M)
# **Version:** `X.Y.Z`, released DD.MM.YYYY
README_RE = re.compile(r"(\*\*Version:\*\* `)([^`]+)(`, released )(\d{2}\.\d{2}\.\d{4})")


# The Windows port shares the version: (file, pattern whose group 2 is the version, matches to change).
WINDOWS_FILES = [
    (WIN / "package.json", re.compile(r'(\n  "version":\s*")([^"]+)(")'), 1),
    # Root version, then the root package entry ("" in "packages").
    (WIN / "package-lock.json", re.compile(r'(\n(?:  |      )"version":\s*")([^"]+)(")'), 2),
    (WIN / "src-tauri" / "tauri.conf.json", re.compile(r'(\n  "version":\s*")([^"]+)(")'), 1),
    (WIN / "src-tauri" / "Cargo.toml", re.compile(r'(\nversion = ")([^"]+)(")'), 1),
    (WIN / "src-tauri" / "Cargo.lock", re.compile(r'(name = "focusedit"\nversion = ")([^"]+)(")'), 1),
]


class VersionError(Exception):
    pass


# --- reading -----------------------------------------------------------------

def read(path: Path) -> str:
    """Read without newline translation, so writing back keeps the file's line endings."""
    with open(path, encoding="utf-8", newline="") as f:
        return f.read()


def write(path: Path, text: str) -> None:
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)


def read_source() -> str:
    text = read(PLIST)
    m = PLIST_RE.search(text)
    if not m:
        raise VersionError("CFBundleShortVersionString not found in Info.plist")
    return m.group(2).strip()


def latest_changelog() -> tuple[str, str] | None:
    if not CHANGELOG.exists():
        return None
    m = RELEASED_RE.search(read(CHANGELOG))
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

    if README.exists():
        m = README_RE.search(read(README))
        if m is None:
            print("readme     README.md       MISSING (no **Version:** line)")
            ok = False
        else:
            mark = "OK" if m.group(2) == source else "DIFF"
            if m.group(2) != source:
                ok = False
            print(f"readme     README.md       {m.group(2)}  ({m.group(4)})  {mark}")

    for path, pattern, count in WINDOWS_FILES:
        if not path.exists():
            continue
        found = [m.group(2) for m in pattern.finditer(read(path))][:count]
        bad = [v for v in found if v != source]
        if not found or bad:
            ok = False
        label = str(path.relative_to(ROOT))
        print(f"windows    {label:<34}{', '.join(found) or 'MISSING'}  {'DIFF' if bad or not found else 'OK'}")

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


def set_readme(text: str, version: str, date: str) -> str:
    y, m, d = date.split("-")
    new, n = README_RE.subn(lambda g: g.group(1) + version + g.group(3) + f"{d}.{m}.{y}", text)
    if n == 0:
        raise VersionError("Could not update README.md (no **Version:** line)")
    return new


def apply(version: str, date: str, dry_run: bool) -> None:
    normalize(version)
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date):
        raise VersionError(f"release date must be YYYY-MM-DD: {date}")
    plist_text = read(PLIST)
    new_plist = set_plist(plist_text, version)

    changelog_text = read(CHANGELOG) if CHANGELOG.exists() else ""
    new_changelog = set_changelog(changelog_text, version, date) if changelog_text else changelog_text

    readme_text = read(README) if README.exists() else ""
    new_readme = set_readme(readme_text, version, date) if readme_text else readme_text

    windows = []
    for path, pattern, count in WINDOWS_FILES:
        if not path.exists():
            continue
        text = read(path)
        new, n = pattern.subn(lambda m: m.group(1) + version + m.group(3), text, count=count)
        if n < count:
            raise VersionError(f"Could not update {path.relative_to(ROOT)} (pattern changed)")
        windows.append((path, text, new))

    print(f"Target version:      {version}")
    print(f"Target release date: {date}\n")

    changed = []
    if new_plist != plist_text:
        changed.append((PLIST, new_plist))
    if changelog_text and new_changelog != changelog_text:
        changed.append((CHANGELOG, new_changelog))
    if readme_text and new_readme != readme_text:
        changed.append((README, new_readme))

    changed += [(path, new) for path, text, new in windows if new != text]

    if not changed:
        print("Nothing to update (already in sync).")
        return

    for path, content in changed:
        rel = path.relative_to(ROOT)
        if dry_run:
            print(f"Would update {rel}")
        else:
            write(path, content)
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
