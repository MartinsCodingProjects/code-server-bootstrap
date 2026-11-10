"""Session control for the Session Config page and the cards: the folder list, the saved
selection, and starting/stopping through the same agent-* commands the terminal uses."""

import json
import math
import re
import shutil
import subprocess
from datetime import datetime, timedelta
from pathlib import Path

from .config import Config
from .live import tmux_name, tmux_sessions

# Never offered as project folders.
SKIP = {"node_modules", "__pycache__", "venv", "dist", "build", "target", "vendor", "coverage", "out", "tmp"}


def _subfolders(folder: Path) -> list[Path]:
    try:
        return sorted((p for p in folder.iterdir()
                       if p.is_dir() and not p.name.startswith(".") and p.name not in SKIP),
                      key=lambda p: p.name.lower())
    except OSError:
        return []


def folders(cfg: Config, selected: list[str]) -> list[dict]:
    """Folders below PROJECTS_DIR, two levels deep, as a flat list in tree order."""
    running = {t["project"]: t for t in tmux_sessions().values()}
    sel = set(selected)

    def entry(p: Path, depth: int) -> dict:
        rel = p.relative_to(cfg.projects_dir).as_posix()
        t = running.get(rel)
        return {
            "rel": rel,
            "name": p.name,
            "depth": depth,
            "git": (p / ".git").exists(),
            "selected": rel in sel,
            "running": bool(t and not t["dead"]),
            "exited": bool(t and t["dead"]),
            "session": tmux_name(rel),
        }

    out = []
    for top in _subfolders(cfg.projects_dir):
        e = entry(top, 1)
        children = [entry(c, 2) for c in _subfolders(top)]
        e["children"] = len(children)
        out.append(e)
        out += children
    return out


def valid_folder(cfg: Config, rel: str) -> bool:
    """Only existing folders strictly inside PROJECTS_DIR (no '..', no symlinks out)."""
    if not rel or rel.startswith("/") or "\\" in rel:
        return False
    try:
        root = cfg.projects_dir.resolve()
        p = (root / rel).resolve()
        return p.is_dir() and p != root and root in p.parents
    except OSError:
        return False


def save_selection(cfg: Config, rels: list[str]) -> list[str]:
    rels = sorted({r.strip("/") for r in rels if valid_folder(cfg, r.strip("/"))})
    cfg.data_dir.mkdir(parents=True, exist_ok=True)
    tmp = cfg.data_dir / "selection.json.tmp"
    tmp.write_text(json.dumps({"folders": rels}, indent=2) + "\n")
    tmp.replace(cfg.data_dir / "selection.json")
    return rels


def _agent(*args) -> dict:
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=40)
        return {"ok": r.returncode == 0, "output": (r.stdout + r.stderr).strip()}
    except (OSError, subprocess.SubprocessError) as exc:
        return {"ok": False, "output": str(exc)}


def start(cfg: Config, rel: str, resume: bool = False) -> dict:
    if not valid_folder(cfg, rel):
        return {"folder": rel, "ok": False, "output": "not a folder below the projects folder"}
    args = ["agent-start", rel] + (["--continue"] if resume else [])
    return {"folder": rel} | _agent(*args)


def stop(cfg: Config, rel: str) -> dict:
    if not valid_folder(cfg, rel):
        return {"folder": rel, "ok": False, "output": "not a folder below the projects folder"}
    return {"folder": rel} | _agent("agent-stop", rel)


# --- creating and deleting project folders ------------------------------------------------------

NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
TRASH = ".trash"  # below PROJECTS_DIR; hidden, so never listed as a project
TRASH_DAYS = 30


def _git(folder: Path, *args) -> tuple[int, str]:
    try:
        r = subprocess.run(["git", "-C", str(folder), *args], capture_output=True, text=True, timeout=10)
        return r.returncode, r.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return 1, ""


def create_folder(cfg: Config, name: str) -> dict:
    """A new project directly in PROJECTS_DIR, as a git repository (branch main) from the start."""
    if not NAME_RE.match(name or ""):
        return {"ok": False, "output": "Name: Buchstaben, Ziffern, '.', '_' und '-', höchstens 64 Zeichen, "
                                       "beginnt mit Buchstabe oder Ziffer"}
    path = cfg.projects_dir / name
    try:
        path.mkdir()
    except FileExistsError:
        return {"ok": False, "output": f"„{name}“ gibt es schon"}
    except OSError as exc:
        return {"ok": False, "output": str(exc)}
    code, _ = _git(path, "init", "-q", "-b", "main")
    out = f"{name} angelegt, " + ("Git-Repository (main) initialisiert" if code == 0 else "git init fehlgeschlagen")
    return {"ok": True, "folder": name, "output": out}


def _repo_state(path: Path, rel: str) -> dict:
    _, porcelain = _git(path, "status", "--porcelain")
    _, remote = _git(path, "remote", "get-url", "origin")
    code, ahead = _git(path, "rev-list", "--count", "@{upstream}..HEAD")
    _, commits = _git(path, "rev-list", "--count", "--all")
    return {
        "folder": rel,
        "changed": len(porcelain.splitlines()) if porcelain else 0,
        "remote": remote or None,
        "unpushed": int(ahead) if code == 0 and ahead.isdigit() else None,  # None: no upstream branch
        "commits": int(commits) if commits.isdigit() else 0,
    }


def folder_info(cfg: Config, rel: str) -> dict | None:
    """What deleting a folder would affect: repositories in it (itself or one level down),
    their unsaved work, running agent sessions, size."""
    if not valid_folder(cfg, rel):
        return None
    path = cfg.projects_dir / rel
    repos = []
    if (path / ".git").exists():
        repos.append(_repo_state(path, rel))
    else:
        for child in _subfolders(path):
            if (child / ".git").exists():
                repos.append(_repo_state(child, f"{rel}/{child.name}"))
    files, size, capped = 0, 0, False
    for p in path.rglob("*"):  # stops early in huge trees (node_modules, ...)
        if files >= 200_000:
            capped = True
            break
        try:
            if p.is_file() and not p.is_symlink():
                files += 1
                size += p.stat().st_size
        except OSError:
            pass
    running = sorted(t["project"] for t in tmux_sessions().values()
                     if t["project"] == rel or t["project"].startswith(rel + "/"))
    return {"folder": rel, "repos": repos, "files": files, "bytes": size, "capped": capped, "running": running}


def trash_folder(cfg: Config, rel: str, confirm: str) -> dict:
    """Moves the folder to PROJECTS_DIR/.trash (deleted for good after TRASH_DAYS days)."""
    rel = rel.strip("/")
    if not valid_folder(cfg, rel) or any(part.startswith(".") for part in rel.split("/")):
        return {"ok": False, "output": "kein Projektordner"}
    if confirm != rel.rsplit("/", 1)[-1]:
        return {"ok": False, "output": "Zur Bestätigung den Ordnernamen genau eintippen"}
    running = [t["project"] for t in tmux_sessions().values()
               if t["project"] == rel or t["project"].startswith(rel + "/")]
    if running:
        return {"ok": False, "output": "Erst die Agent-Sessions stoppen: " + ", ".join(sorted(running))}
    trash = cfg.projects_dir / TRASH
    trash.mkdir(exist_ok=True)
    now = datetime.now()
    target = trash / f"{rel.replace('/', '__')}--{now.strftime('%Y%m%d-%H%M%S')}"
    try:
        (cfg.projects_dir / rel).rename(target)
    except OSError as exc:
        return {"ok": False, "output": str(exc)}
    # where it came from, for the trash list and restoring (the name alone is ambiguous)
    target.with_name(target.name + ".json").write_text(
        json.dumps({"folder": rel, "deleted": now.isoformat(timespec="seconds")}) + "\n")
    save_selection(cfg, [f for f in _selected(cfg) if f != rel and not f.startswith(rel + "/")])
    return {"ok": True, "folder": rel, "trash": str(target),
            "output": f"{rel} in den Papierkorb verschoben ({TRASH}/{target.name}, {TRASH_DAYS} Tage)"}


def _selected(cfg: Config) -> list[str]:
    try:
        return json.loads((cfg.data_dir / "selection.json").read_text()).get("folders", [])
    except (OSError, ValueError, AttributeError):
        return []


def _trash_entries(cfg: Config) -> list[dict]:
    out = []
    for entry in (cfg.projects_dir / TRASH).glob("*--*"):
        if not entry.is_dir():
            continue
        try:
            moved = datetime.strptime(entry.name.rsplit("--", 1)[1], "%Y%m%d-%H%M%S")
        except ValueError:
            continue
        try:
            folder = json.loads(entry.with_name(entry.name + ".json").read_text())["folder"]
        except (OSError, ValueError, KeyError):
            folder = entry.name.rsplit("--", 1)[0].replace("__", "/")
        out.append({"id": entry.name, "path": entry, "folder": folder, "deleted": moved})
    return sorted(out, key=lambda e: e["deleted"], reverse=True)


def trash_list(cfg: Config) -> list[dict]:
    now = datetime.now()
    return [{
        "id": e["id"],
        "folder": e["folder"],
        "deleted": e["deleted"].isoformat(timespec="seconds"),
        "purge": (e["deleted"] + timedelta(days=TRASH_DAYS)).isoformat(timespec="seconds"),
        "days_left": max(0, math.ceil((e["deleted"] + timedelta(days=TRASH_DAYS) - now).total_seconds() / 86400)),
        "occupied": (cfg.projects_dir / e["folder"]).exists(),
    } for e in _trash_entries(cfg)]


def restore_folder(cfg: Config, entry_id: str) -> dict:
    """Moves a trash entry back to where it was deleted from."""
    entry = next((e for e in _trash_entries(cfg) if e["id"] == entry_id), None)
    if entry is None:
        return {"ok": False, "output": "nicht (mehr) im Papierkorb"}
    rel = entry["folder"]
    target = cfg.projects_dir / rel
    root = cfg.projects_dir.resolve()
    if ".." in rel.split("/") or root not in target.resolve().parents:
        return {"ok": False, "output": "ungültiger Ursprungsort"}
    if target.exists():
        return {"ok": False, "output": f"„{rel}“ gibt es inzwischen wieder; erst umbenennen oder löschen"}
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        entry["path"].rename(target)
    except OSError as exc:
        return {"ok": False, "output": str(exc)}
    entry["path"].with_name(entry["id"] + ".json").unlink(missing_ok=True)
    return {"ok": True, "folder": rel, "output": f"{rel} wiederhergestellt"}


def purge_trash(cfg: Config):
    """Deletes trash entries older than TRASH_DAYS (by the time in their name)."""
    limit = datetime.now() - timedelta(days=TRASH_DAYS)
    for e in _trash_entries(cfg):
        if e["deleted"] < limit:
            shutil.rmtree(e["path"], ignore_errors=True)
            e["path"].with_name(e["id"] + ".json").unlink(missing_ok=True)
