"""Reads the files the hook and the status line append to (~/.claude/agent-events/*.jsonl,
~/.claude/agent-samples/*.jsonl) from where it stopped last time. The files are the durable
record: while the dashboard is down nothing is lost, it catches up on start."""

import json
import logging
import time
from pathlib import Path

from .config import Config
from .events import from_hook
from .store import Store

log = logging.getLogger(__name__)


def _new_lines(store: Store, path: Path) -> list[dict]:
    try:
        size = path.stat().st_size
    except OSError:
        return []
    offset = store.file_offset(str(path))
    if size < offset:  # replaced or truncated: read it again
        offset = 0
    if size == offset:
        return []
    with path.open("rb") as f:
        f.seek(offset)
        chunk = f.read(size - offset)
    end = chunk.rfind(b"\n")
    if end < 0:
        return []  # a line still being written
    out = []
    for raw in chunk[: end + 1].splitlines():
        try:
            out.append(json.loads(raw))
        except ValueError:
            log.warning("skipping a malformed line in %s", path)
    store.set_file_offset(str(path), offset + end + 1)
    return out


def ingest(store: Store, cfg: Config) -> list[dict]:
    """One pass over both folders; returns the new history events (with ids)."""
    events = []
    for path in sorted(cfg.events_dir.glob("*.jsonl")):
        lines = _new_lines(store, path)
        if lines:
            events += store.add_events([from_hook(line, cfg.projects_dir) for line in lines])
    for path in sorted(cfg.samples_dir.glob("*.jsonl")):
        lines = _new_lines(store, path)
        if lines:
            store.add_samples(lines)
    return events


def prune(store: Store, cfg: Config):
    """Retention: database rows, day files and status snapshots older than retention_days."""
    day = store.prune(cfg.retention_days)
    for folder in (cfg.events_dir, cfg.samples_dir):
        for path in folder.glob("*.jsonl"):
            if path.stem < day:
                path.unlink(missing_ok=True)
    store.forget_files_before(day)
    limit = time.time() - cfg.retention_days * 86400
    for path in cfg.state_dir.glob("*.json"):
        try:
            if path.stat().st_mtime < limit:
                path.unlink()
        except OSError:
            pass
