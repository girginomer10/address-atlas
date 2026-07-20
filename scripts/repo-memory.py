#!/usr/bin/env python3
"""Repo-scoped semantic memory backed by curated Markdown and local SQLite.

The SQLite file is a disposable search cache. Only Markdown under the curated
memory categories is indexed; repository source files and handoff logs are not.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import sqlite3
import stat
import subprocess
import sys
from collections import Counter
from dataclasses import dataclass
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit, urlunsplit


SCHEMA_VERSION = 1
# Feature hashing stores only non-zero coordinates, so a larger dimension does
# not create dense rows. It substantially reduces false lexical collisions
# between short, unrelated curated notes.
VECTOR_DIMENSIONS = 4_096
MIN_SEARCH_SCORE = 0.03
MAX_NOTE_BYTES = 256 * 1024
INDEXED_STATUSES = {"active", "needs-review"}
VALID_STATUSES = INDEXED_STATUSES | {"deprecated", "superseded"}
CATEGORIES = (
    "architecture",
    "decisions",
    "bugfixes",
    "gotchas",
    "file-map",
    "api-notes",
)
TEMPLATE_BY_CATEGORY = {
    "architecture": "architecture.md",
    "decisions": "decision.md",
    "bugfixes": "bugfix.md",
    "gotchas": "gotcha.md",
    "file-map": "file-map.md",
    "api-notes": "api-note.md",
}
SECRET_PATTERNS = (
    ("private key", re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----")),
    ("OpenAI-style key", re.compile(r"\b(?:sk|pk)-[A-Za-z0-9_-]{20,}\b")),
    ("GitHub token", re.compile(r"\bgh[pousr]_[A-Za-z0-9_]{20,}\b")),
    ("AWS access key", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    ("Google API key", re.compile(r"\bAIza[0-9A-Za-z_-]{30,}\b")),
    ("Slack token", re.compile(r"\bxox[baprs]-[0-9A-Za-z-]{20,}\b")),
    ("Stripe live secret", re.compile(r"\bsk_live_[0-9A-Za-z]{16,}\b")),
    ("JWT", re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b")),
    ("Bearer token", re.compile(r"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{20,}")),
    ("credential-bearing URL", re.compile(r"(?i)\b[a-z][a-z0-9+.-]*://[^\s/:@]+:[^\s/@]+@")),
    (
        "credential variable",
        re.compile(
            r"(?i)\b[A-Za-z0-9_]*(?:api[_-]?key|access[_-]?token|refresh[_-]?token|password|"
            r"client[_-]?secret|session[_-]?secret|private[_-]?key|secret[_-]?key)"
            r"\s*[:=]\s*[\"']?[A-Za-z0-9/+_.=-]{12,}"
        ),
    ),
    (
        "assigned credential",
        re.compile(
            r"(?i)\b(?:api[_ -]?key|access[_ -]?token|refresh[_ -]?token|password|client[_ -]?secret)"
            r"\s*[:=]\s*[\"']?[A-Za-z0-9/+_.=-]{12,}"
        ),
    ),
)


@dataclass(frozen=True)
class Note:
    path: Path
    source: str
    content: str
    metadata: dict[str, Any]
    body: str


def run_git(root: Path, *args: str) -> str:
    completed = subprocess.run(
        ["git", "-C", str(root), *args],
        check=False,
        capture_output=True,
        text=True,
    )
    return completed.stdout.strip() if completed.returncode == 0 else ""


def repository_root() -> Path:
    cwd = Path.cwd().resolve()
    root = run_git(cwd, "rev-parse", "--show-toplevel")
    return Path(root).resolve() if root else cwd


def sanitize_remote(remote: str) -> str:
    """Normalize a Git remote without retaining embedded credentials."""
    remote = remote.strip()
    if not remote:
        return ""
    if any(ord(character) < 32 for character in remote):
        return ""
    if "://" in remote:
        parsed = urlsplit(remote)
        host = parsed.hostname or ""
        if parsed.scheme != "file" and not host:
            return ""
        if ":" in host and not host.startswith("["):
            host = f"[{host}]"
        try:
            port = parsed.port
        except ValueError:
            return ""
        if port is not None:
            host = f"{host}:{port}"
        return urlunsplit((parsed.scheme.casefold(), host.casefold(), parsed.path.rstrip("/"), "", ""))
    # Git's SCP-like syntax is usually git@host:owner/repo. Dropping the user
    # both normalizes equivalent remotes and avoids persisting token-like users.
    return re.sub(r"^[^/@:\s]+@(?=[^:]+:)", "", remote).rstrip("/")


def repository_identity(root: Path) -> tuple[str, str]:
    remote = sanitize_remote(run_git(root, "config", "--get", "remote.origin.url"))
    if detect_secret(remote):
        # A pathological remote can still carry a credential in its path. The
        # resolved root alone is a safe, stable fallback for this local cache.
        remote = ""
    # Include the resolved root as well as the remote. Two clones of the same
    # upstream can contain different branches and must not overwrite each
    # other's local cache.
    identity = f"{root}\n{remote}"
    suffix = hashlib.sha256(identity.encode("utf-8")).hexdigest()[:12]
    basename = re.sub(r"[^a-z0-9._-]+", "-", root.name.lower()).strip("-") or "repo"
    return f"{basename}-{suffix}", remote


def database_path() -> Path:
    configured = os.environ.get("CODEX_REPO_MEMORY_DB")
    if configured:
        # Normalize relative paths without resolving the final component. A
        # caller-supplied database symlink must remain visible to the explicit
        # O_NOFOLLOW/symlink checks below; resolving it here would operate on
        # (and potentially delete) the target instead of refusing the link.
        return Path(os.path.abspath(Path(configured).expanduser()))
    return Path.home() / ".codex-memory" / "chroma_db" / "repo-memory.sqlite3"


def is_within(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def validate_database_location(root: Path, path: Path) -> None:
    if is_within(path.resolve(), root.resolve()):
        raise RuntimeError(
            "The semantic-memory database must live outside the repository; "
            "choose an external CODEX_REPO_MEMORY_DB path"
        )


def database_artifact_paths(path: Path) -> tuple[Path, ...]:
    return (path, Path(f"{path}-wal"), Path(f"{path}-shm"), Path(f"{path}-journal"))


def secure_database_artifacts(path: Path) -> None:
    for artifact in database_artifact_paths(path):
        if artifact.is_symlink():
            raise RuntimeError(f"Semantic-memory database artifact must not be a symlink: {artifact}")
        flags = os.O_RDONLY | getattr(os, "O_NONBLOCK", 0)
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        try:
            descriptor = os.open(artifact, flags)
        except FileNotFoundError:
            continue
        except OSError as error:
            if artifact.is_symlink():
                raise RuntimeError(
                    f"Semantic-memory database artifact must not be a symlink: {artifact}"
                ) from error
            raise
        try:
            metadata = os.fstat(descriptor)
            if not stat.S_ISREG(metadata.st_mode):
                raise RuntimeError(f"Semantic-memory database artifact is not a regular file: {artifact}")
            if metadata.st_nlink != 1:
                raise RuntimeError(f"Semantic-memory database artifact must not be hard-linked: {artifact}")
            os.fchmod(descriptor, 0o600)
        finally:
            os.close(descriptor)


def _connect_database_once(path: Path) -> sqlite3.Connection:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    secure_database_artifacts(path)
    flags = os.O_CREAT | os.O_RDWR
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags, 0o600)
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise RuntimeError(f"Semantic-memory database is not a regular file: {path}")
        os.fchmod(descriptor, 0o600)
    finally:
        os.close(descriptor)
    connection = sqlite3.connect(path)
    try:
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA journal_mode=WAL")
        connection.execute("PRAGMA foreign_keys=ON")
        connection.executescript(
            """
            CREATE TABLE IF NOT EXISTS collections (
              repo_id TEXT PRIMARY KEY,
              root TEXT NOT NULL,
              remote TEXT NOT NULL,
              schema_version INTEGER NOT NULL,
              vector_dimensions INTEGER NOT NULL,
              updated_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS documents (
              repo_id TEXT NOT NULL,
              source TEXT NOT NULL,
              content_hash TEXT NOT NULL,
              title TEXT NOT NULL,
              status TEXT NOT NULL,
              tags TEXT NOT NULL,
              related_files TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              PRIMARY KEY (repo_id, source),
              FOREIGN KEY (repo_id) REFERENCES collections(repo_id) ON DELETE CASCADE
            );
            CREATE TABLE IF NOT EXISTS chunks (
              repo_id TEXT NOT NULL,
              source TEXT NOT NULL,
              chunk_index INTEGER NOT NULL,
              heading TEXT NOT NULL,
              content TEXT NOT NULL,
              vector TEXT NOT NULL,
              PRIMARY KEY (repo_id, source, chunk_index),
              FOREIGN KEY (repo_id, source)
                REFERENCES documents(repo_id, source) ON DELETE CASCADE
            );
            CREATE INDEX IF NOT EXISTS chunks_repo_source ON chunks(repo_id, source);
            """
        )
        quick_check = connection.execute("PRAGMA quick_check").fetchone()
        if quick_check is None or quick_check[0] != "ok":
            raise sqlite3.DatabaseError("database disk image is malformed (SQLite quick_check failed)")
        secure_database_artifacts(path)
        return connection
    except BaseException:
        connection.close()
        raise


def is_database_corruption(error: sqlite3.DatabaseError) -> bool:
    message = str(error).casefold()
    return any(
        marker in message
        for marker in ("file is not a database", "database disk image is malformed", "malformed database schema")
    )


def connect_database(path: Path, *, recover_corrupt: bool = False) -> sqlite3.Connection:
    try:
        return _connect_database_once(path)
    except sqlite3.DatabaseError as error:
        if not recover_corrupt or not is_database_corruption(error):
            raise
        secure_database_artifacts(path)
        for artifact in reversed(database_artifact_paths(path)):
            try:
                artifact.unlink()
            except FileNotFoundError:
                pass
        print("repo-memory: corrupt local cache removed; rebuilding it from curated Markdown", file=sys.stderr)
        return _connect_database_once(path)


def strip_yaml_comment(value: str) -> str:
    quote: str | None = None
    escaped = False
    for index, character in enumerate(value):
        if escaped:
            escaped = False
            continue
        if character == "\\" and quote == '"':
            escaped = True
            continue
        if quote:
            if character == quote:
                quote = None
            continue
        if character in {"'", '"'}:
            quote = character
            continue
        if character == "#" and (index == 0 or value[index - 1].isspace()):
            return value[:index].strip()
    if quote:
        raise ValueError("unclosed quote in frontmatter value")
    return value.strip()


def parse_scalar(value: str) -> str:
    value = strip_yaml_comment(value)
    if not value:
        return ""
    if value[0] in {"'", '"'}:
        quote = value[0]
        if len(value) < 2 or value[-1] != quote:
            raise ValueError("unclosed quote in frontmatter value")
        if quote == '"':
            try:
                parsed = json.loads(value)
            except json.JSONDecodeError as error:
                raise ValueError("invalid double-quoted frontmatter value") from error
            if not isinstance(parsed, str):
                raise ValueError("frontmatter scalar must be a string")
            return parsed
        return value[1:-1].replace("''", "'")
    if value[-1] in {"'", '"'}:
        raise ValueError("unmatched quote in frontmatter value")
    return value


def parse_list(value: str) -> list[str]:
    value = strip_yaml_comment(value)
    if not value:
        return []
    if value.startswith("[") and value.endswith("]"):
        inner = value[1:-1].strip()
        if not inner:
            return []
        items: list[str] = []
        start = 0
        quote: str | None = None
        escaped = False
        for index, character in enumerate(inner):
            if escaped:
                escaped = False
                continue
            if character == "\\" and quote == '"':
                escaped = True
                continue
            if quote:
                if character == quote:
                    quote = None
                continue
            if character in {"'", '"'}:
                quote = character
            elif character == ",":
                items.append(parse_scalar(inner[start:index].strip()))
                start = index + 1
        if quote:
            raise ValueError("unclosed quote in frontmatter list")
        items.append(parse_scalar(inner[start:].strip()))
        return items
    if value.startswith("[") or value.endswith("]"):
        raise ValueError("malformed inline frontmatter list")
    return [parse_scalar(value)]


def parse_note(content: str, source: str) -> tuple[dict[str, Any], str]:
    content = content.removeprefix("\ufeff").replace("\r\n", "\n").replace("\r", "\n")
    if not content.startswith("---\n"):
        raise ValueError(f"{source}: missing YAML-style frontmatter")
    marker = content.find("\n---\n", 4)
    if marker < 0:
        raise ValueError(f"{source}: unclosed frontmatter")
    raw_header = content[4:marker]
    body = content[marker + 5 :].strip()
    metadata: dict[str, Any] = {}
    for line in raw_header.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if ":" not in line:
            raise ValueError(f"{source}: malformed frontmatter line: {line}")
        key, value = line.split(":", 1)
        key = key.strip()
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_-]*", key):
            raise ValueError(f"{source}: invalid frontmatter key: {key!r}")
        if key in metadata:
            raise ValueError(f"{source}: duplicate frontmatter key: {key}")
        try:
            metadata[key] = parse_list(value) if key in {"tags", "related_files"} else parse_scalar(value)
        except ValueError as error:
            raise ValueError(f"{source}: {error}") from error
    return metadata, body


def detect_secret(content: str) -> str | None:
    for label, pattern in SECRET_PATTERNS:
        if pattern.search(content):
            return label
    return None


def assert_safe_repo_path(root: Path, path: Path, *, label: str) -> None:
    root = root.resolve()
    try:
        relative = path.absolute().relative_to(root)
    except ValueError as error:
        raise RuntimeError(f"{label} escapes the repository: {path}") from error
    current = root
    for part in relative.parts:
        current /= part
        if current.is_symlink():
            raise RuntimeError(f"{label} must not use symbolic links: {path.relative_to(root)}")
    try:
        resolved = path.resolve(strict=True)
    except FileNotFoundError as error:
        raise RuntimeError(f"{label} does not exist: {path.relative_to(root)}") from error
    if not is_within(resolved, root):
        raise RuntimeError(f"{label} resolves outside the repository: {path.relative_to(root)}")


def read_safe_text(path: Path, *, label: str, max_bytes: int = MAX_NOTE_BYTES) -> str:
    flags = os.O_RDONLY | getattr(os, "O_NONBLOCK", 0)
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise RuntimeError(f"{label} is not a regular file: {path}")
        if metadata.st_nlink != 1:
            raise RuntimeError(f"{label} must not be hard-linked: {path}")
        if metadata.st_size > max_bytes:
            raise RuntimeError(f"{label} exceeds the {max_bytes}-byte limit: {path}")
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(descriptor, min(64 * 1024, max_bytes + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > max_bytes:
                raise RuntimeError(f"{label} exceeds the {max_bytes}-byte limit: {path}")
        return b"".join(chunks).decode("utf-8")
    finally:
        os.close(descriptor)


def ensure_safe_directory(root: Path, directory: Path) -> None:
    root = root.resolve()
    try:
        relative = directory.absolute().relative_to(root)
    except ValueError as error:
        raise RuntimeError(f"Memory directory escapes the repository: {directory}") from error
    current = root
    for part in relative.parts:
        current /= part
        if current.is_symlink():
            raise RuntimeError(f"Memory directory must not use symbolic links: {current.relative_to(root)}")
        if current.exists():
            if not current.is_dir():
                raise RuntimeError(f"Memory path is not a directory: {current.relative_to(root)}")
        else:
            current.mkdir()


def note_paths(root: Path) -> list[Path]:
    base = root / "memory"
    paths: list[Path] = []
    for category in CATEGORIES:
        directory = base / category
        if directory.exists():
            paths.extend(directory.rglob("*.md"))
    return sorted(paths)


def memory_symlink_errors(root: Path) -> list[str]:
    base = root / "memory"
    if not base.exists() and not base.is_symlink():
        return []
    if base.is_symlink():
        return ["Memory directory must not use symbolic links: memory"]
    errors: list[str] = []
    for directory, child_directories, filenames in os.walk(base, followlinks=False):
        child_directories.sort()
        filenames.sort()
        current = Path(directory)
        for name in [*child_directories, *filenames]:
            candidate = current / name
            if candidate.is_symlink():
                errors.append(
                    f"Memory paths must not use symbolic links: {candidate.relative_to(root).as_posix()}"
                )
    return errors


def scan_notes(root: Path) -> tuple[list[Note], list[str], list[str]]:
    notes: list[Note] = []
    errors = memory_symlink_errors(root)
    security_warnings: list[str] = []
    if errors:
        return notes, errors, security_warnings
    for path in note_paths(root):
        try:
            assert_safe_repo_path(root, path, label="Memory note")
            source = path.relative_to(root).as_posix()
            content = read_safe_text(path, label=source)
            secret = detect_secret(content)
            if secret:
                security_warnings.append(f"{source}: possible {secret}")
                continue
            metadata, body = parse_note(content, source)
            note_errors = validate_metadata(metadata, source)
            if not body.strip():
                note_errors.append(f"{source}: note body is empty")
            if note_errors:
                errors.extend(note_errors)
                continue
            notes.append(Note(path, source, content, metadata, body))
        except (OSError, RuntimeError, UnicodeError, ValueError) as error:
            errors.append(str(error))
    return notes, errors, security_warnings


def tokenize(text: str) -> list[str]:
    return re.findall(r"[\w][\w./:@-]*", text.casefold(), flags=re.UNICODE)


def feature_vector(text: str) -> dict[str, float]:
    tokens = tokenize(text)
    features = tokens + [f"{left}::{right}" for left, right in zip(tokens, tokens[1:])]
    counts = Counter(features)
    vector: dict[int, float] = {}
    for feature, count in counts.items():
        digest = hashlib.blake2b(feature.encode("utf-8"), digest_size=8).digest()
        raw = int.from_bytes(digest, "big")
        index = raw % VECTOR_DIMENSIONS
        sign = -1.0 if raw & (1 << 63) else 1.0
        vector[index] = vector.get(index, 0.0) + sign * (1.0 + math.log(count))
    norm = math.sqrt(sum(value * value for value in vector.values()))
    if norm:
        vector = {index: value / norm for index, value in vector.items()}
    return {str(index): round(value, 10) for index, value in vector.items()}


def cosine(left: dict[str, float], right: dict[str, float]) -> float:
    if len(left) > len(right):
        left, right = right, left
    return sum(value * right.get(index, 0.0) for index, value in left.items())


def chunk_note(title: str, body: str, max_chars: int = 1_600) -> list[tuple[str, str]]:
    sections: list[tuple[str, list[str]]] = []
    heading = title
    lines: list[str] = []
    for line in body.splitlines():
        match = re.match(r"^#{1,6}\s+(.+?)\s*$", line)
        if match:
            if lines:
                sections.append((heading, lines))
            heading = match.group(1)
            lines = []
        else:
            lines.append(line)
    if lines or not sections:
        sections.append((heading, lines))

    chunks: list[tuple[str, str]] = []
    for section_heading, section_lines in sections:
        paragraphs = [part.strip() for part in "\n".join(section_lines).split("\n\n") if part.strip()]
        current = f"{title}\n{section_heading}" if section_heading != title else title
        for paragraph in paragraphs:
            if len(current) + len(paragraph) + 2 > max_chars and current.strip() != title:
                chunks.append((section_heading, current.strip()))
                current = f"{title}\n{section_heading}\n{paragraph}"
            else:
                current = f"{current}\n{paragraph}"
        if current.strip():
            chunks.append((section_heading, current.strip()))
    return chunks or [(title, title)]


def ensure_layout(root: Path) -> None:
    ensure_safe_directory(root, root / "memory")
    ensure_safe_directory(root, root / "memory" / "templates")
    for category in CATEGORIES:
        ensure_safe_directory(root, root / "memory" / category)


def clean_related_path(value: str) -> str:
    return re.sub(r":\d+(?:-\d+)?$", "", value.strip())


def validate_related_path(value: str, source: str) -> str | None:
    clean = clean_related_path(value)
    if not clean:
        return f"{source}: related_files contains an empty path"
    if "\\" in clean:
        return f"{source}: related file paths must use repository-relative POSIX syntax: {value}"
    if clean.startswith("~") or re.match(r"^[A-Za-z][A-Za-z0-9+.-]*://", clean):
        return f"{source}: related file must be a repository path, not a home path or URI: {value}"
    if any(ord(character) < 32 for character in clean):
        return f"{source}: related file path contains control characters"
    candidate = Path(clean)
    if candidate.is_absolute() or ".." in candidate.parts:
        return f"{source}: related file must be repository-relative: {value}"
    return None


def validate_metadata(metadata: dict[str, Any], source: str) -> list[str]:
    errors: list[str] = []
    for required in ("title", "date", "status", "tags", "related_files"):
        if required not in metadata:
            errors.append(f"{source}: missing {required}")
    for required in ("title", "date", "status"):
        if required in metadata and not str(metadata[required]).strip():
            errors.append(f"{source}: missing {required}")
    title = str(metadata.get("title", ""))
    if len(title) > 200:
        errors.append(f"{source}: title must not exceed 200 characters")
    tags = metadata.get("tags")
    if not isinstance(tags, list) or not tags:
        errors.append(f"{source}: tags must be a non-empty inline list")
    elif any(not str(tag).strip() for tag in tags):
        errors.append(f"{source}: tags must not contain empty values")
    elif len(tags) > 32 or any(len(str(tag)) > 64 for tag in tags):
        errors.append(f"{source}: tags exceed the count or length limit")
    related_files = metadata.get("related_files")
    if not isinstance(related_files, list):
        errors.append(f"{source}: related_files must be an inline list")
    else:
        if len(related_files) > 64 or any(len(str(related)) > 512 for related in related_files):
            errors.append(f"{source}: related_files exceed the count or length limit")
        for related in related_files:
            error = validate_related_path(str(related), source)
            if error:
                errors.append(error)
    status = metadata.get("status")
    if status and status not in VALID_STATUSES:
        errors.append(f"{source}: invalid status {status!r}")
    raw_date = metadata.get("date")
    if raw_date:
        try:
            date.fromisoformat(str(raw_date))
        except ValueError:
            errors.append(f"{source}: date must be YYYY-MM-DD")
    return errors


def cached_note_is_intact(
    connection: sqlite3.Connection,
    repo_id: str,
    note: Note,
    document: sqlite3.Row,
) -> bool:
    status = str(note.metadata["status"])
    content_hash = hashlib.sha256(note.content.encode("utf-8")).hexdigest()
    if status not in INDEXED_STATUSES:
        return True
    if document["content_hash"] != content_hash or document["status"] != status:
        # This is an ordinary source update; the incremental sync will replace it.
        return True
    try:
        tags = list(note.metadata["tags"])
        related_files = list(note.metadata["related_files"])
        if (
            document["title"] != str(note.metadata["title"])
            or json.loads(document["tags"]) != tags
            or json.loads(document["related_files"]) != related_files
        ):
            return False
        rows = connection.execute(
            """
            SELECT chunk_index, heading, content, vector
            FROM chunks
            WHERE repo_id = ? AND source = ?
            ORDER BY chunk_index
            """,
            (repo_id, note.source),
        ).fetchall()
        expected_chunks = chunk_note(str(note.metadata["title"]), note.body)
        if len(rows) != len(expected_chunks):
            return False
        for index, ((heading, content), row) in enumerate(zip(expected_chunks, rows)):
            searchable = "\n".join(
                (str(note.metadata["title"]), " ".join(tags), " ".join(related_files), content)
            )
            if (
                row["chunk_index"] != index
                or row["heading"] != heading
                or row["content"] != content
                or json.loads(row["vector"]) != feature_vector(searchable)
            ):
                return False
    except (json.JSONDecodeError, TypeError, ValueError):
        return False
    return True


def sync(root: Path, *, force: bool = False, quiet: bool = False) -> dict[str, Any]:
    ensure_layout(root)
    repo_id, remote = repository_identity(root)
    db_path = database_path()
    validate_database_location(root, db_path)
    notes, metadata_errors, security_warnings = scan_notes(root)
    validation_errors = metadata_errors + security_warnings
    if validation_errors:
        raise RuntimeError("Memory validation errors:\n- " + "\n- ".join(validation_errors))

    connection = connect_database(db_path, recover_corrupt=True)
    scanned = indexed = updated = skipped = 0
    removed = stale_collections_removed = 0
    try:
        # Serialize cache inspection and mutation so two agents cannot both
        # make skip/update decisions from a stale document snapshot.
        connection.execute("BEGIN IMMEDIATE")
        collection = connection.execute(
            "SELECT schema_version, vector_dimensions FROM collections WHERE repo_id = ?", (repo_id,)
        ).fetchone()
        schema_rebuild = bool(
            collection
            and (
                collection["schema_version"] != SCHEMA_VERSION
                or collection["vector_dimensions"] != VECTOR_DIMENSIONS
            )
        )
        existing = {
            row["source"]: row
            for row in connection.execute(
                """
                SELECT source, content_hash, title, status, tags, related_files
                FROM documents
                WHERE repo_id = ?
                """,
                (repo_id,),
            )
        }
        cache_rebuild = any(
            note.source in existing
            and not cached_note_is_intact(connection, repo_id, note, existing[note.source])
            for note in notes
        )
        rebuild = force or schema_rebuild or cache_rebuild
        if rebuild:
            existing = {}
        scanned = len(notes)
        seen = {note.source for note in notes}
        now = datetime.now(timezone.utc).isoformat()

        with connection:
            # Remove namespaces left by older identity rules or a changed
            # remote only when they belong to this exact working tree.
            stale_collections = connection.execute(
                "SELECT repo_id FROM collections WHERE root = ? AND repo_id <> ?",
                (str(root), repo_id),
            ).fetchall()
            for row in stale_collections:
                connection.execute("DELETE FROM collections WHERE repo_id = ?", (row["repo_id"],))
            stale_collections_removed = len(stale_collections)

            if rebuild:
                connection.execute("DELETE FROM collections WHERE repo_id = ?", (repo_id,))
            connection.execute(
                """
                INSERT INTO collections(repo_id, root, remote, schema_version, vector_dimensions, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(repo_id) DO UPDATE SET
                  root=excluded.root,
                  remote=excluded.remote,
                  schema_version=excluded.schema_version,
                  vector_dimensions=excluded.vector_dimensions,
                  updated_at=excluded.updated_at
                """,
                (repo_id, str(root), remote, SCHEMA_VERSION, VECTOR_DIMENSIONS, now),
            )

            for note in notes:
                source = note.source
                metadata = note.metadata
                status = str(metadata["status"])
                if status not in INDEXED_STATUSES:
                    if source in existing:
                        connection.execute(
                            "DELETE FROM documents WHERE repo_id = ? AND source = ?", (repo_id, source)
                        )
                        updated += 1
                    skipped += 1
                    continue
                content_hash = hashlib.sha256(note.content.encode("utf-8")).hexdigest()
                previous = existing.get(source)
                if (
                    not rebuild
                    and previous
                    and previous["content_hash"] == content_hash
                    and previous["status"] == status
                ):
                    skipped += 1
                    continue

                title = str(metadata["title"])
                tags = list(metadata["tags"])
                related_files = list(metadata["related_files"])
                connection.execute(
                    """
                    INSERT INTO documents(repo_id, source, content_hash, title, status, tags, related_files, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(repo_id, source) DO UPDATE SET
                      content_hash=excluded.content_hash,
                      title=excluded.title,
                      status=excluded.status,
                      tags=excluded.tags,
                      related_files=excluded.related_files,
                      updated_at=excluded.updated_at
                    """,
                    (
                        repo_id,
                        source,
                        content_hash,
                        title,
                        status,
                        json.dumps(tags, ensure_ascii=False),
                        json.dumps(related_files, ensure_ascii=False),
                        now,
                    ),
                )
                connection.execute("DELETE FROM chunks WHERE repo_id = ? AND source = ?", (repo_id, source))
                for index, (heading, chunk) in enumerate(chunk_note(title, note.body)):
                    searchable = "\n".join((title, " ".join(tags), " ".join(related_files), chunk))
                    connection.execute(
                        """
                        INSERT INTO chunks(repo_id, source, chunk_index, heading, content, vector)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                        (repo_id, source, index, heading, chunk, json.dumps(feature_vector(searchable))),
                    )
                if previous and not rebuild:
                    updated += 1
                else:
                    indexed += 1

            if not rebuild:
                for source in sorted(set(existing) - seen):
                    connection.execute(
                        "DELETE FROM documents WHERE repo_id = ? AND source = ?", (repo_id, source)
                    )
                    removed += 1
    finally:
        connection.close()
        secure_database_artifacts(db_path)

    result = {
        "mode": "reindex" if rebuild else "sync",
        "repo_id": repo_id,
        "database": str(db_path),
        "scanned": scanned,
        "indexed": indexed,
        "updated": updated,
        "removed": removed,
        "skipped": skipped,
        "stale_collections_removed": stale_collections_removed,
    }
    if not quiet:
        print(json.dumps(result, indent=2, ensure_ascii=False))
    return result


def reindex(root: Path) -> None:
    sync(root, force=True)


def search(root: Path, query: str, top_k: int) -> None:
    query = query.strip()
    if not query:
        raise RuntimeError("Search query must not be empty")
    sync(root, quiet=True)
    repo_id, _ = repository_identity(root)
    db_path = database_path()
    validate_database_location(root, db_path)
    connection = connect_database(db_path)
    try:
        query_vector = feature_vector(query)
        rows = connection.execute(
            """
            SELECT c.source, c.heading, c.content, c.vector,
                   d.title, d.status, d.tags, d.related_files
            FROM chunks c
            JOIN documents d ON d.repo_id = c.repo_id AND d.source = c.source
            WHERE c.repo_id = ?
            ORDER BY c.source, c.chunk_index
            """,
            (repo_id,),
        ).fetchall()
        best_by_source: dict[str, tuple[float, sqlite3.Row]] = {}
        for row in rows:
            score = cosine(query_vector, json.loads(row["vector"]))
            current = best_by_source.get(row["source"])
            if current is None or score > current[0]:
                best_by_source[row["source"]] = (score, row)
        ranked = sorted(
            (candidate for candidate in best_by_source.values() if candidate[0] >= MIN_SEARCH_SCORE),
            key=lambda item: (-item[0], str(item[1]["source"])),
        )[:top_k]
        output = []
        for score, row in ranked:
            excerpt = re.sub(r"\s+", " ", row["content"]).strip()
            if len(excerpt) > 420:
                excerpt = excerpt[:417].rstrip() + "..."
            output.append(
                {
                    "title": row["title"],
                    "source": row["source"],
                    "tags": json.loads(row["tags"]),
                    "status": row["status"],
                    "related_files": json.loads(row["related_files"]),
                    "score": round(score, 4),
                    "excerpt": excerpt,
                }
            )
    finally:
        connection.close()
        secure_database_artifacts(db_path)
    print(json.dumps({"query": query, "repo_id": repo_id, "results": output}, indent=2, ensure_ascii=False))


def add_note(root: Path, category: str, slug: str) -> None:
    ensure_layout(root)
    if category not in TEMPLATE_BY_CATEGORY:
        raise RuntimeError(f"Unknown category {category!r}; choose one of {', '.join(CATEGORIES)}")
    safe_slug = re.sub(r"[^a-z0-9-]+", "-", slug.casefold()).strip("-")
    if not safe_slug:
        raise RuntimeError("The note slug must contain letters or numbers")
    template = root / "memory" / "templates" / TEMPLATE_BY_CATEGORY[category]
    if not template.is_file():
        raise RuntimeError(f"Missing template: {template.relative_to(root)}")
    assert_safe_repo_path(root, template, label="Memory template")
    destination = root / "memory" / category / f"{date.today().isoformat()}-{safe_slug}.md"
    if destination.exists() or destination.is_symlink():
        raise RuntimeError(f"Note already exists: {destination.relative_to(root)}")
    title = safe_slug.replace("-", " ").strip().capitalize()
    content = read_safe_text(template, label="Memory template")
    content = content.replace("YYYY-MM-DD", date.today().isoformat(), 1)
    content = re.sub(r"^title: .+$", f"title: {title}", content, count=1, flags=re.MULTILINE)
    content = re.sub(r"^related_files: .+$", "related_files: []", content, count=1, flags=re.MULTILINE)
    with destination.open("x", encoding="utf-8") as handle:
        handle.write(content)
    print(destination.relative_to(root))


def doctor(root: Path) -> None:
    errors: list[str] = []
    warnings: list[str] = []
    security_warnings: list[str] = []
    sync_result: dict[str, Any] | None = None
    required = [
        root / "memory" / "README.md",
        root / "AGENTS.md",
        root / "scripts" / "repo-memory.py",
        root / "memory" / "templates",
    ]
    required.extend(root / "memory" / category for category in CATEGORIES)
    required.extend(root / "memory" / "templates" / template for template in TEMPLATE_BY_CATEGORY.values())
    for path in required:
        if path.is_symlink():
            errors.append(f"Memory installation path must not use symbolic links: {path.relative_to(root)}")
        elif not path.exists():
            errors.append(f"missing {path.relative_to(root)}")
        else:
            try:
                assert_safe_repo_path(root, path, label="Memory installation path")
            except RuntimeError as error:
                errors.append(str(error))
    agents = ""
    agents_path = root / "AGENTS.md"
    if agents_path.is_file() and not agents_path.is_symlink():
        try:
            agents = read_safe_text(agents_path, label="AGENTS.md")
        except (OSError, RuntimeError, UnicodeError) as error:
            errors.append(str(error))
    start_marker = "<!-- repo-semantic-memory:start -->"
    end_marker = "<!-- repo-semantic-memory:end -->"
    if (
        agents.count(start_marker) != 1
        or agents.count(end_marker) != 1
        or agents.find(start_marker) > agents.find(end_marker)
    ):
        errors.append("AGENTS.md must contain one ordered managed Repo Semantic Memory section")

    for template_name in TEMPLATE_BY_CATEGORY.values():
        template_path = root / "memory" / "templates" / template_name
        if not template_path.is_file() or template_path.is_symlink():
            continue
        source = template_path.relative_to(root).as_posix()
        try:
            content = read_safe_text(template_path, label=source)
            secret = detect_secret(content)
            if secret:
                security_warnings.append(f"{source}: possible {secret}")
                errors.append(security_warnings[-1])
                continue
            metadata, body = parse_note(content.replace("YYYY-MM-DD", date.today().isoformat(), 1), source)
            errors.extend(validate_metadata(metadata, source))
            if not body.strip():
                errors.append(f"{source}: template body is empty")
        except (OSError, RuntimeError, UnicodeError, ValueError) as error:
            errors.append(str(error))

    package_path = root / "package.json"
    if package_path.is_file():
        try:
            assert_safe_repo_path(root, package_path, label="package.json")
            package = json.loads(read_safe_text(package_path, label="package.json"))
            if not isinstance(package, dict) or not isinstance(package.get("scripts"), dict):
                raise RuntimeError("package.json scripts must be an object")
            scripts = package["scripts"]
            for command in ("init", "add", "sync", "search", "reindex", "doctor"):
                name = f"memory:{command}"
                expected = f"python3 scripts/repo-memory.py {command}"
                if scripts.get(name) != expected:
                    errors.append(f"package.json is missing the exact {name} command")
        except (OSError, RuntimeError, UnicodeError, json.JSONDecodeError) as error:
            errors.append(f"package.json could not be validated: {error}")

    tree_errors = memory_symlink_errors(root)
    note_path_count = (
        len(note_paths(root)) if (root / "memory").is_dir() and not tree_errors else 0
    )
    if note_path_count == 0 and not tree_errors:
        errors.append("no curated memory notes were found")
    notes, note_errors, detected_secrets = scan_notes(root)
    errors.extend(note_errors)
    security_warnings.extend(detected_secrets)
    errors.extend(detected_secrets)
    for note in notes:
        if note.metadata.get("status") == "needs-review":
            warnings.append(f"{note.source}: status is needs-review")
        for related in note.metadata.get("related_files", []):
            clean = clean_related_path(str(related))
            if any(character in clean for character in "*?[]"):
                try:
                    matches = list(root.glob(clean))
                except (OSError, ValueError) as error:
                    errors.append(f"{note.source}: invalid related file pattern {related!r}: {error}")
                    continue
                if not matches:
                    warnings.append(f"{note.source}: related file pattern has no matches: {related}")
                elif any(not is_within(match.resolve(), root) for match in matches):
                    errors.append(
                        f"{note.source}: related file pattern resolves outside the repository: {related}"
                    )
                continue
            target = root / clean
            if not target.exists():
                warnings.append(f"{note.source}: related file does not exist: {related}")
            elif target.is_symlink() and not is_within(target.resolve(), root):
                errors.append(f"{note.source}: related file resolves outside the repository: {related}")

    db_path = database_path()
    try:
        validate_database_location(root, db_path)
    except RuntimeError as error:
        errors.append(str(error))

    if not errors:
        try:
            sync_result = sync(root, quiet=True)
        except (OSError, RuntimeError, sqlite3.Error, ValueError) as error:
            errors.append(f"synchronization failed: {error}")

    repo_id, _ = repository_identity(root)
    document_count = 0
    if not errors and db_path.exists():
        connection = connect_database(db_path)
        try:
            collection = connection.execute(
                "SELECT schema_version, vector_dimensions FROM collections WHERE repo_id = ?", (repo_id,)
            ).fetchone()
            document_rows = connection.execute(
                "SELECT source FROM documents WHERE repo_id = ? ORDER BY source", (repo_id,)
            ).fetchall()
            document_sources = {str(row["source"]) for row in document_rows}
            document_count = len(document_sources)
            expected_sources = {
                note.source for note in notes if str(note.metadata["status"]) in INDEXED_STATUSES
            }
            if collection is None:
                errors.append("repository collection is missing")
            elif (
                collection["schema_version"] != SCHEMA_VERSION
                or collection["vector_dimensions"] != VECTOR_DIMENSIONS
            ):
                errors.append("repository collection schema is stale; run memory:reindex")
            if document_sources != expected_sources:
                errors.append("indexed document sources do not match active curated Markdown notes")
            empty_chunk_sources = connection.execute(
                """
                SELECT d.source
                FROM documents d
                LEFT JOIN chunks c ON c.repo_id = d.repo_id AND c.source = d.source
                WHERE d.repo_id = ?
                GROUP BY d.source
                HAVING COUNT(c.chunk_index) = 0
                """,
                (repo_id,),
            ).fetchall()
            if empty_chunk_sources:
                errors.append("one or more indexed notes have no searchable chunks")
            quick_check = connection.execute("PRAGMA quick_check").fetchone()[0]
            if quick_check != "ok":
                errors.append(f"SQLite quick_check failed: {quick_check}")
            if connection.execute("PRAGMA foreign_key_check").fetchone() is not None:
                errors.append("SQLite foreign-key check failed")
        finally:
            connection.close()
            secure_database_artifacts(db_path)
        for artifact in database_artifact_paths(db_path):
            if not artifact.exists():
                continue
            mode = stat.S_IMODE(artifact.stat().st_mode)
            if mode & 0o077:
                security_warnings.append(
                    f"local database artifact permissions are too broad ({mode:o}): {artifact}"
                )
                errors.append(security_warnings[-1])
    elif not errors:
        errors.append("repository collection database is missing")

    report = {
        "healthy": not errors,
        "repo_id": repo_id,
        "database": str(db_path),
        "notes_scanned": note_path_count,
        "notes_indexed": document_count,
        "sync": sync_result or {"status": "blocked"},
        "stale_or_needs_review": sorted(set(warnings)),
        "security_warnings": sorted(set(security_warnings)),
        "errors": list(dict.fromkeys(errors)),
        "manual_setup": "none; local deterministic indexing needs no API key",
    }
    print(json.dumps(report, indent=2, ensure_ascii=False))
    if errors:
        raise SystemExit(1)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("init", help="Create missing category directories and synchronize the local index")
    commands.add_parser("sync", help="Incrementally synchronize curated notes")
    commands.add_parser("reindex", help="Rebuild this repository's local collection")
    commands.add_parser("doctor", help="Validate source notes and the local collection")
    add = commands.add_parser("add", help="Create a dated note from a category template")
    add.add_argument("category", choices=CATEGORIES)
    add.add_argument("slug")
    search_parser = commands.add_parser("search", help="Search this repository's curated memory")
    search_parser.add_argument("query")
    search_parser.add_argument("--top-k", type=int, default=8)
    return parser


def main() -> None:
    args = build_parser().parse_args()
    root = repository_root()
    try:
        if args.command in {"init", "sync"}:
            sync(root)
        elif args.command == "reindex":
            reindex(root)
        elif args.command == "search":
            if not 1 <= args.top_k <= 50:
                raise RuntimeError("--top-k must be between 1 and 50")
            search(root, args.query, args.top_k)
        elif args.command == "add":
            add_note(root, args.category, args.slug)
        elif args.command == "doctor":
            doctor(root)
    except (OSError, RuntimeError, sqlite3.Error, ValueError) as error:
        print(f"repo-memory: {error}", file=sys.stderr)
        raise SystemExit(1) from error


if __name__ == "__main__":
    main()
