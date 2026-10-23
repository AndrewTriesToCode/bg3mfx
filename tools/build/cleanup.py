#!/usr/bin/env python3
"""Safely remove disposable build binaries or retained evidence folders."""

import argparse
import os
from pathlib import Path
import shutil
import sys


def absolute_lexical(path):
    """Make a path absolute without following symlinks."""
    path = Path(path).expanduser()
    if not path.is_absolute():
        path = Path.cwd() / path
    return Path(os.path.abspath(path))


def has_symlink_component(path):
    current = Path(path.anchor)
    for component in path.parts[1:]:
        current /= component
        if current.is_symlink():
            return current
    return None


def validate_cleanup_paths(bin_dir, evidence_dir):
    paths = {
        "bin": absolute_lexical(bin_dir),
        "evidence": absolute_lexical(evidence_dir),
    }
    for label, path in paths.items():
        if path.name != label:
            raise ValueError(f"{label} cleanup path must end in '{label}': {path}")
        link = has_symlink_component(path)
        if link:
            raise ValueError(f"cleanup path contains a symlink: {link}")

    binary, evidence = paths["bin"], paths["evidence"]
    if binary == evidence or binary in evidence.parents or evidence in binary.parents:
        raise ValueError(f"bin and evidence cleanup paths overlap: {binary} and {evidence}")
    return paths


def clean(path):
    if not path.exists():
        return
    if not path.is_dir():
        raise ValueError(f"cleanup target is not a directory: {path}")
    shutil.rmtree(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", choices=("bin", "evidence"))
    parser.add_argument("bin_dir", type=Path)
    parser.add_argument("evidence_dir", type=Path)
    args = parser.parse_args()
    try:
        paths = validate_cleanup_paths(args.bin_dir, args.evidence_dir)
        clean(paths[args.target])
    except (OSError, ValueError) as error:
        print(f"build-cleanup: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
