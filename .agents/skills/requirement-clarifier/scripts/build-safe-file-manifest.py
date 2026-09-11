#!/usr/bin/env python3
"""Build a read allowlist for project-associated requirement analysis."""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
import sys
from pathlib import Path


BLOCKED_DIRECTORY_NAMES = {
    ".git",
    ".hg",
    ".svn",
    ".venv",
    "node_modules",
    "dist",
    "build",
    "coverage",
    "__pycache__",
}
BLOCKED_SUFFIXES = {
    ".key",
    ".pem",
    ".p12",
    ".pfx",
    ".kdb",
    ".jks",
    ".sqlite",
    ".sqlite3",
    ".db",
    ".dump",
    ".bak",
    ".log",
}
SAFE_ENV_TEMPLATES = {".env.example", ".env.sample", ".env.template"}
SENSITIVE_NAME_PATTERN = re.compile(
    r"(^|[._-])(credential|credentials|secret|secrets|password|passwd|token|tokens|private-key)([._-]|$)",
    re.IGNORECASE,
)
SECRET_CONTENT_PATTERNS = (
    ("private-key", re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----")),
    ("aws-access-key", re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b")),
    ("jwt", re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b")),
    (
        "assigned-secret",
        re.compile(
            r"(?i)\b(?:api[_-]?key|client[_-]?secret|access[_-]?token|password|passwd)\b"
            r"\s*[:=]\s*[\"']?[A-Za-z0-9/+_.-]{12,}"
        ),
    ),
    (
        "connection-string-password",
        re.compile(r"(?i)\b(?:password|pwd)\s*=\s*[^;\s]{6,}"),
    ),
)


def is_reparse_point(path: Path) -> bool:
    try:
        attributes = path.lstat().st_file_attributes
    except AttributeError:
        return path.is_symlink()
    except OSError:
        return True
    return bool(attributes & stat.FILE_ATTRIBUTE_REPARSE_POINT)


def has_reparse_component(project_root: Path, candidate: Path) -> bool:
    relative = candidate.relative_to(project_root)
    current = project_root
    for part in relative.parts:
        current = current / part
        if is_reparse_point(current):
            return True
    return False


def has_submodule_component(project_root: Path, candidate: Path) -> bool:
    relative = candidate.relative_to(project_root)
    current = project_root
    for part in relative.parts[:-1]:
        current = current / part
        if (current / ".git").is_file():
            return True
    return False


def is_within_root(project_root: Path, candidate: Path) -> bool:
    try:
        candidate.relative_to(project_root)
        return True
    except ValueError:
        return False


def blocked_path_reason(relative: Path) -> str | None:
    lower_parts = {part.lower() for part in relative.parts[:-1]}
    if lower_parts & BLOCKED_DIRECTORY_NAMES:
        return "blocked-directory"

    name = relative.name
    lower_name = name.lower()
    if lower_name.startswith(".env") and lower_name not in SAFE_ENV_TEMPLATES:
        return "environment-file"
    if Path(lower_name).suffix in BLOCKED_SUFFIXES:
        return "sensitive-file-type"
    if SENSITIVE_NAME_PATTERN.search(lower_name):
        return "sensitive-file-name"
    return None


def inspect_content(path: Path, max_bytes: int) -> str | None:
    data = path.read_bytes()
    if len(data) > max_bytes:
        return "file-too-large"
    if b"\x00" in data[:8192]:
        return "binary-file"
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return "non-utf8-file"
    for reason, pattern in SECRET_CONTENT_PATTERNS:
        if pattern.search(text):
            return f"secret-content:{reason}"
    return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-root", required=True)
    parser.add_argument("--candidate", action="append", default=[], required=True)
    parser.add_argument("--max-files", type=int, default=200)
    parser.add_argument("--max-bytes", type=int, default=1_048_576)
    args = parser.parse_args()

    if args.max_files < 1 or args.max_files > 500:
        parser.error("--max-files must be between 1 and 500")
    if args.max_bytes < 1 or args.max_bytes > 5_242_880:
        parser.error("--max-bytes must be between 1 and 5242880")
    if len(args.candidate) > args.max_files:
        parser.error("candidate count exceeds --max-files")

    project_root = Path(args.project_root).resolve(strict=True)
    if not project_root.is_dir():
        parser.error("--project-root must be a directory")
    if is_reparse_point(project_root):
        parser.error("--project-root must not be a reparse point")

    allowed: list[str] = []
    blocked: list[dict[str, str]] = []
    seen: set[str] = set()

    for raw_candidate in args.candidate:
        supplied = Path(raw_candidate)
        unresolved = supplied if supplied.is_absolute() else project_root / supplied
        lexical_candidate = Path(os.path.abspath(unresolved))
        display_path = str(supplied)
        if not is_within_root(project_root, lexical_candidate):
            blocked.append({"path": display_path, "reason": "outside-project-root"})
            continue
        if has_reparse_component(project_root, lexical_candidate):
            blocked.append({"path": display_path, "reason": "reparse-point"})
            continue
        if has_submodule_component(project_root, lexical_candidate):
            blocked.append({"path": display_path, "reason": "submodule-path"})
            continue
        try:
            resolved = unresolved.resolve(strict=True)
        except (OSError, RuntimeError):
            blocked.append({"path": display_path, "reason": "missing-or-unresolvable"})
            continue

        normalized = os.path.normcase(str(resolved))
        if normalized in seen:
            continue
        seen.add(normalized)

        if not is_within_root(project_root, resolved):
            blocked.append({"path": display_path, "reason": "outside-project-root"})
            continue
        if not resolved.is_file():
            blocked.append({"path": display_path, "reason": "not-a-file"})
            continue

        relative = resolved.relative_to(project_root)
        reason = blocked_path_reason(relative)
        if reason is None:
            try:
                reason = inspect_content(resolved, args.max_bytes)
            except OSError:
                reason = "unreadable"

        if reason is None:
            allowed.append(str(resolved))
        else:
            blocked.append({"path": str(relative), "reason": reason})

    result = {
        "version": 1,
        "project_root": str(project_root),
        "limits": {"max_files": args.max_files, "max_bytes": args.max_bytes},
        "allowed": allowed,
        "blocked": blocked,
    }
    json.dump(result, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
