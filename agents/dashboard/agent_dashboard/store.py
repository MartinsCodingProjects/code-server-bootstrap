"""SQLite store: history events, status line samples, OpenTelemetry metrics and per-session state.
All access happens on the event loop thread (async endpoints and tasks), behind one lock."""

import json
import sqlite3
import threading
from datetime import datetime, timedelta, timezone
from pathlib import Path

from .events import dumps, hook_status, norm_ts

SCHEMA = """
CREATE TABLE IF NOT EXISTS events(
  id INTEGER PRIMARY KEY, ts TEXT NOT NULL, source TEXT NOT NULL, project TEXT, session_id TEXT,
  event TEXT NOT NULL, category TEXT NOT NULL, summary TEXT, data TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS events_ts ON events(ts, id);
CREATE INDEX IF NOT EXISTS events_project ON events(project, ts);
CREATE INDEX IF NOT EXISTS events_session ON events(session_id, ts);
CREATE TABLE IF NOT EXISTS samples(
  id INTEGER PRIMARY KEY, ts TEXT NOT NULL, project TEXT, session_id TEXT, data TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS samples_ts ON samples(ts);
CREATE TABLE IF NOT EXISTS metrics(
  id INTEGER PRIMARY KEY, ts TEXT NOT NULL, project TEXT, session_id TEXT, name TEXT NOT NULL,
  value REAL, attrs TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS metrics_ts ON metrics(ts);
CREATE TABLE IF NOT EXISTS sessions(
  session_id TEXT PRIMARY KEY, project TEXT, tmux TEXT, cwd TEXT, transcript_path TEXT,
  first_ts TEXT, last_ts TEXT, status TEXT, status_ts TEXT, last_event TEXT, last_summary TEXT);
CREATE INDEX IF NOT EXISTS sessions_project ON sessions(project, last_ts);
CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY, offset INTEGER NOT NULL);
"""

EVENT_COLUMNS = "id, ts, source, project, session_id, event, category, summary"


class Store:
    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=NORMAL")
        self.db.executescript(SCHEMA)
        self.lock = threading.Lock()

    # --- writing ---------------------------------------------------------------------------------

    def add_events(self, events: list[dict]) -> list[dict]:
        """Inserts events, updates the sessions they belong to; returns them with their ids."""
        out = []
        with self.lock, self.db:
            for e in events:
                cur = self.db.execute(
                    "INSERT INTO events(ts, source, project, session_id, event, category, summary, data)"
                    " VALUES(?,?,?,?,?,?,?,?)",
                    (e["ts"], e["source"], e["project"], e["session_id"], e["event"], e["category"],
                     e["summary"], dumps(e["data"])))
                if e["session_id"] and e["source"] == "hook":
                    self._touch_session(e)
                out.append({k: e[k] for k in ("ts", "source", "project", "session_id", "event", "category", "summary")}
                           | {"id": cur.lastrowid})
        return out

    def _touch_session(self, e: dict):
        d = e["data"]
        status = hook_status(d)
        row = self.db.execute("SELECT last_ts FROM sessions WHERE session_id=?", (e["session_id"],)).fetchone()
        if row is None:
            self.db.execute(
                "INSERT INTO sessions(session_id, project, tmux, cwd, transcript_path, first_ts, last_ts,"
                " status, status_ts, last_event, last_summary) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                (e["session_id"], e["project"], d.get("tmux"), d.get("cwd"), d.get("transcript_path"),
                 e["ts"], e["ts"], status or "input", e["ts"], e["event"], e["summary"]))
            return
        if e["ts"] < row["last_ts"]:
            return  # late arrival; the newer state stands
        self.db.execute(
            "UPDATE sessions SET project=COALESCE(?, project), tmux=COALESCE(?, tmux),"
            " transcript_path=COALESCE(?, transcript_path), last_ts=?, last_event=?, last_summary=?"
            " WHERE session_id=?",
            (e["project"], d.get("tmux"), d.get("transcript_path"), e["ts"], e["event"], e["summary"],
             e["session_id"]))
        if status:
            self.db.execute("UPDATE sessions SET status=?, status_ts=? WHERE session_id=?",
                            (status, e["ts"], e["session_id"]))

    def add_samples(self, samples: list[dict]):
        with self.lock, self.db:
            self.db.executemany(
                "INSERT INTO samples(ts, project, session_id, data) VALUES(?,?,?,?)",
                [(norm_ts(s.get("ts")), s.get("project"), s.get("session_id"), dumps(s)) for s in samples])

    def add_metrics(self, metrics: list[dict]):
        with self.lock, self.db:
            self.db.executemany(
                "INSERT INTO metrics(ts, project, session_id, name, value, attrs) VALUES(?,?,?,?,?,?)",
                [(m["ts"], m["project"], m["session_id"], m["name"], m["value"], dumps(m["attrs"]))
                 for m in metrics])

    def file_offset(self, path: str) -> int:
        with self.lock:
            row = self.db.execute("SELECT offset FROM files WHERE path=?", (path,)).fetchone()
        return row["offset"] if row else 0

    def set_file_offset(self, path: str, offset: int):
        with self.lock, self.db:
            self.db.execute("INSERT INTO files(path, offset) VALUES(?,?)"
                            " ON CONFLICT(path) DO UPDATE SET offset=excluded.offset", (path, offset))

    def prune(self, days: int) -> str:
        """Deletes everything older than `days`; returns the cutoff date (YYYY-MM-DD)."""
        cutoff = datetime.now(timezone.utc) - timedelta(days=days)
        ts = cutoff.strftime("%Y-%m-%dT%H:%M:%S.000Z")
        with self.lock, self.db:
            for table in ("events", "samples", "metrics"):
                self.db.execute(f"DELETE FROM {table} WHERE ts < ?", (ts,))
            self.db.execute("DELETE FROM sessions WHERE last_ts < ?", (ts,))
        return cutoff.strftime("%Y-%m-%d")

    def forget_files_before(self, day: str):
        with self.lock, self.db:
            rows = self.db.execute("SELECT path FROM files").fetchall()
            for r in rows:
                if Path(r["path"]).stem < day:
                    self.db.execute("DELETE FROM files WHERE path=?", (r["path"],))

    # --- reading ---------------------------------------------------------------------------------

    def query_events(self, *, project=None, session=None, categories=None, sources=None, q=None,
                     since=None, until=None, before=None, limit=200) -> list[dict]:
        """Newest first. `before` is a cursor "ts|id" from the last row of the previous page."""
        where, args = [], []
        if project:
            where.append("(project = ? OR project LIKE ?)")
            args += [project, project + "/%"]
        if session:
            where.append("session_id = ?")
            args.append(session)
        if categories:
            where.append(f"category IN ({','.join('?' * len(categories))})")
            args += categories
        if sources:
            where.append(f"source IN ({','.join('?' * len(sources))})")
            args += sources
        if q:
            where.append("(summary LIKE ? OR event LIKE ? OR project LIKE ?)")
            args += [f"%{q}%"] * 3
        if since:
            where.append("ts >= ?")
            args.append(norm_ts(since))
        if until:
            where.append("ts <= ?")
            args.append(norm_ts(until))
        if before:
            ts, _, rid = before.partition("|")
            where.append("(ts < ? OR (ts = ? AND id < ?))")
            args += [ts, ts, int(rid or 0)]
        sql = f"SELECT {EVENT_COLUMNS} FROM events"
        if where:
            sql += " WHERE " + " AND ".join(where)
        sql += " ORDER BY ts DESC, id DESC LIMIT ?"
        args.append(limit)
        with self.lock:
            return [dict(r) for r in self.db.execute(sql, args)]

    def event(self, event_id: int) -> dict | None:
        with self.lock:
            row = self.db.execute(f"SELECT {EVENT_COLUMNS}, data FROM events WHERE id=?", (event_id,)).fetchone()
        if not row:
            return None
        out = dict(row)
        out["data"] = json.loads(out["data"])
        return out

    def projects(self) -> list[str]:
        with self.lock:
            rows = self.db.execute("SELECT DISTINCT project FROM events WHERE project IS NOT NULL ORDER BY project")
            return [r["project"] for r in rows]

    def sessions(self, since_ts: str) -> list[dict]:
        with self.lock:
            rows = self.db.execute("SELECT * FROM sessions WHERE last_ts >= ? ORDER BY last_ts DESC", (since_ts,))
            return [dict(r) for r in rows]

    def latest_sessions_by_tmux(self) -> dict[str, dict]:
        with self.lock:
            rows = self.db.execute(
                "SELECT * FROM sessions WHERE tmux IS NOT NULL ORDER BY last_ts ASC").fetchall()
        return {r["tmux"]: dict(r) for r in rows}  # the newest wins
