#!/usr/bin/env python3
"""Fail closed when tracked files contain private artifacts or credential shapes."""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
from pathlib import Path


MAX_FILE_BYTES = 4 * 1024 * 1024
MAX_AGGREGATE_BYTES = 64 * 1024 * 1024

SENSITIVE_FILENAMES = (
    "authkey_*.p8",
    "*.p8",
    "*.ppk",
    "*.kdbx",
    "*.agekey",
    "*.dump.age",
    "*.dump.age.*",
    "*.atlas-recovery",
    "*.keychain",
    "*.keychain-db",
    "*.mobileprovision",
    "*.cer",
    "*.der",
    "*.jks",
    "*.keystore",
    "*.p12",
    "*.pfx",
    "*.pem",
    "*.key",
    ".netrc",
    ".npmrc",
)

DETECTORS = (
    (
        "private-key",
        re.compile(r"-----BEGIN (?:(?:RSA|EC|DSA|OPENSSH|ENCRYPTED) )?PRIVATE KEY-----"),
    ),
    (
        "pgp-private-key",
        re.compile(r"-----BEGIN PGP " r"PRIVATE KEY BLOCK-----"),
    ),
    ("age-secret-key", re.compile(r"AGE-SECRET-KEY-1[A-Z0-9]{40,}")),
    ("openai-style-key", re.compile(r"\b(?:sk|pk)-[A-Za-z0-9_-]{20,}\b")),
    (
        "github-token",
        re.compile(r"\b(?:gh[pousr]_|github_pat_)[A-Za-z0-9_]{20,}\b"),
    ),
    ("aws-access-key", re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b")),
    ("google-api-key", re.compile(r"\bAIza[0-9A-Za-z_-]{30,}\b")),
    ("slack-token", re.compile(r"\bxox[baprs]-[0-9A-Za-z-]{20,}\b")),
    ("jwt", re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b")),
    ("bearer-token", re.compile(r"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{20,}")),
    (
        "credential-url",
        re.compile(r"(?i)\b[a-z][a-z0-9+.-]*://[^\s/:@]+:[^\s/@]+@"),
    ),
    (
        "credential-assignment",
        re.compile(
            r"(?i)\b[A-Za-z0-9_]*(?:api[_-]?key|access[_-]?token|refresh[_-]?token|"
            r"password|client[_-]?secret|session[_-]?secret|private[_-]?key|secret[_-]?key)"
            r"\s*[:=]\s*[\"']?(?P<assigned_value>[A-Za-z0-9/+_=-]{12,})"
            r"(?![A-Za-z0-9/+_.=-])"
        ),
    ),
)


def tracked_paths(root: Path) -> list[str]:
    result = subprocess.run(
        [
            "git",
            "-C",
            str(root),
            "ls-files",
            "-z",
            "--cached",
            "--others",
            "--exclude-standard",
        ],
        check=True,
        stdout=subprocess.PIPE,
    )
    return [item.decode("utf-8") for item in result.stdout.split(b"\0") if item]


def line_digest(line: str) -> str:
    return hashlib.sha256(line.encode("utf-8")).hexdigest()


class UnsafeScanFileError(Exception):
    """A repository entry cannot be read within the scanner's trust boundary."""


def read_bounded_regular_file(path: Path, initial: os.stat_result) -> bytes:
    """Read one lstat-bound regular file without following a replacement link."""
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = -1
    try:
        descriptor = os.open(path, flags)
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_dev != initial.st_dev
            or opened.st_ino != initial.st_ino
            or opened.st_size != initial.st_size
        ):
            raise UnsafeScanFileError("repository entry changed during inspection")
        chunks: list[bytes] = []
        remaining = opened.st_size
        while remaining:
            chunk = os.read(descriptor, min(remaining, 64 * 1024))
            if not chunk:
                raise UnsafeScanFileError("repository entry was truncated during inspection")
            chunks.append(chunk)
            remaining -= len(chunk)
        if os.read(descriptor, 1):
            raise UnsafeScanFileError("repository entry grew during inspection")
        completed = os.fstat(descriptor)
        if (
            completed.st_dev != opened.st_dev
            or completed.st_ino != opened.st_ino
            or completed.st_size != opened.st_size
        ):
            raise UnsafeScanFileError("repository entry changed during inspection")
        return b"".join(chunks)
    except OSError as error:
        raise UnsafeScanFileError("repository entry could not be opened safely") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def load_allowlist(path: Path) -> dict[tuple[str, str, str], str]:
    if not path.exists():
        return {}
    raw = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict) or set(raw) != {"version", "entries"} or raw["version"] != 1:
        raise ValueError("secret scanner allowlist must use schema version 1")
    if not isinstance(raw["entries"], list):
        raise ValueError("secret scanner allowlist entries must be an array")
    result: dict[tuple[str, str, str], str] = {}
    detector_names = {name for name, _ in DETECTORS}
    for entry in raw["entries"]:
        if not isinstance(entry, dict) or set(entry) != {
            "path",
            "detector",
            "lineSha256",
            "reason",
        }:
            raise ValueError("secret scanner allowlist entry has an unexpected shape")
        source = entry["path"]
        detector = entry["detector"]
        digest = entry["lineSha256"]
        reason = entry["reason"]
        if (
            not isinstance(source, str)
            or source.startswith("/")
            or ".." in Path(source).parts
            or detector not in detector_names
            or not isinstance(digest, str)
            or not re.fullmatch(r"[0-9a-f]{64}", digest)
            or not isinstance(reason, str)
            or not reason.strip()
            or len(reason) > 160
        ):
            raise ValueError("secret scanner allowlist entry is invalid")
        key = (source, detector, digest)
        if key in result:
            raise ValueError("secret scanner allowlist contains a duplicate entry")
        result[key] = reason
    return result


def scan(root: Path, allowlist_path: Path) -> int:
    allowlist = load_allowlist(allowlist_path)
    used_allowlist: set[tuple[str, str, str]] = set()
    violations: list[str] = []
    sources = tracked_paths(root)
    aggregate_bytes = 0
    for source in sources:
        path = root / source
        try:
            metadata = path.lstat()
        except OSError:
            violations.append(f"{source}: cannot inspect repository entry safely")
            continue
        if not stat.S_ISREG(metadata.st_mode):
            violations.append(f"{source}: repository entry must be a regular file")
            continue
        if metadata.st_size > MAX_FILE_BYTES:
            violations.append(
                f"{source}: repository entry exceeds the {MAX_FILE_BYTES}-byte scan limit"
            )
            continue
        if aggregate_bytes + metadata.st_size > MAX_AGGREGATE_BYTES:
            violations.append(
                f"{source}: repository scan exceeds the {MAX_AGGREGATE_BYTES}-byte aggregate limit"
            )
            continue
        aggregate_bytes += metadata.st_size
        basename = Path(source).name.lower()
        normalized = source.lower()
        if any(
            fnmatch.fnmatch(basename, pattern)
            or fnmatch.fnmatch(normalized, f"*/{pattern}")
            for pattern in SENSITIVE_FILENAMES
        ):
            violations.append(f"{source}: tracked private artifact filename")
            continue
        try:
            data = read_bounded_regular_file(path, metadata)
            if b"\0" in data:
                # Binary or mixed-content files are not a trust boundary. A
                # credential can be embedded beside a NUL byte just as easily
                # as in a text file, and every detector is intentionally ASCII.
                # Latin-1 preserves each byte one-to-one so those signatures
                # remain searchable without interpreting arbitrary binary data.
                text = data.decode("latin-1")
            else:
                text = data.decode("utf-8")
        except UnsafeScanFileError:
            violations.append(f"{source}: cannot safely read repository entry")
            continue
        except UnicodeDecodeError:
            violations.append(f"{source}: non-binary repository entry is not valid UTF-8")
            continue
        for line_number, line in enumerate(text.splitlines(), start=1):
            digest = line_digest(line)
            for detector_name, detector in DETECTORS:
                match = detector.search(line)
                if not match:
                    continue
                if detector_name == "credential-assignment":
                    assigned = match.group("assigned_value")
                    # Avoid treating ordinary source-code identifiers as literal
                    # credentials. Distinctive provider formats remain covered by
                    # their dedicated detectors; generic literals must combine
                    # letters and digits.
                    if not any(character.isalpha() for character in assigned) \
                        or not any(character.isdigit() for character in assigned):
                        continue
                key = (source, detector_name, digest)
                if key in allowlist:
                    used_allowlist.add(key)
                else:
                    violations.append(
                        f"{source}:{line_number}: possible {detector_name}; value suppressed"
                    )
    for key in sorted(set(allowlist) - used_allowlist):
        violations.append(
            f"{key[0]}: stale secret-scanner allowlist entry for {key[1]} ({key[2]})"
        )
    if violations:
        print("\n".join(violations), file=sys.stderr)
        return 1
    print(f"secret-artifact hygiene: scanned {len(sources)} repository files")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--allowlist", type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    allowlist = args.allowlist or root / ".github" / "secret-scan-allowlist.json"
    try:
        return scan(root, allowlist.resolve())
    except (OSError, ValueError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
        print(f"secret-artifact hygiene failed closed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
