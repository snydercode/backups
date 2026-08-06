#!/usr/bin/env python3
"""Render backup/jobs.txt from the canonical snyderverse fleet config.

jobs.txt is a GENERATED ARTIFACT. The source of truth is
snyderverse/fleet/config/fleet.yaml, consumed here via the public
`snyderverse.fleet` Python API (never by parsing YAML directly).

Usage:
    render-jobs-from-fleet.py [--check] [--out PATH]

    (default)   write jobs.txt atomically
    --check     render to stdout-compared temp and exit non-zero on drift
    --out PATH  override output path (default: <repo>/jobs.txt)
"""
from __future__ import annotations

import argparse
import os
import sys
import tempfile
from pathlib import Path

try:
    from snyderverse.fleet import load_fleet
except ImportError as exc:  # pragma: no cover - environment guard
    sys.stderr.write(
        "error: cannot import snyderverse.fleet; install the snyderverse "
        f"package in this environment.\n  detail: {exc}\n"
    )
    raise SystemExit(2)

REPO_DIR = Path(__file__).resolve().parent.parent
DEFAULT_OUT = REPO_DIR / "jobs.txt"

HEADER = """\
# backup-kit unified config
#
# DO NOT EDIT. Generated from the snyderverse fleet config
# (snyderverse/fleet/config/fleet.yaml) via bin/render-jobs-from-fleet.py.
# Edit the fleet config and regenerate; manual edits will be overwritten.
#
# Per-host fields:
#   os=linux|wsl
#   user=<linux user>
#   src=<source path>
#   dest=<destination path>   (repeatable, at least one)
#   windows_user=<Windows account>   (wsl hosts only)
"""


def render() -> str:
    """Return the full jobs.txt text rendered from the fleet config."""
    cfg = load_fleet()
    lines: list[str] = [HEADER.rstrip("\n")]
    # Only hosts that have a backup route are emitted; alphabetical order.
    for host in sorted(cfg.backup):
        spec = cfg.hosts[host]
        route = cfg.backup_route(host)
        lines.append("")
        lines.append(f"[{host}]")
        lines.append(f"os={spec.os}")
        lines.append(f"user={spec.user}")
        if spec.os == "wsl":
            lines.append(f"windows_user={spec.windows_user}")
        lines.append(f"src={route.source_root}")
        for dest in route.dest_roots:
            lines.append(f"dest={dest}")
    return "\n".join(lines) + "\n"


def _atomic_write(path: Path, text: str) -> None:
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".jobs.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(text)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="exit non-zero if the target file differs from rendered output",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=DEFAULT_OUT,
        help=f"output path (default: {DEFAULT_OUT})",
    )
    args = parser.parse_args(argv)

    rendered = render()

    if args.check:
        if not args.out.exists():
            sys.stderr.write(f"drift: {args.out} does not exist\n")
            return 1
        current = args.out.read_text()
        if current != rendered:
            sys.stderr.write(
                f"drift: {args.out} is stale; regenerate with "
                "bin/render-jobs-from-fleet.py\n"
            )
            return 1
        return 0

    _atomic_write(args.out, rendered)
    sys.stderr.write(f"wrote {args.out}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
