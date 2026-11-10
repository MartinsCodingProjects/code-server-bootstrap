"""Settings from the environment (set by docker-compose.yml from .env, see bootstrap.sh)."""

import os
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Config:
    projects_dir: Path
    claude_dir: Path  # ~/.claude: agent-events/, agent-samples/, agent-state/
    data_dir: Path  # SQLite database, selection.json
    code_server_url: str  # e.g. https://dev.example.com; empty: no "open in code-server" links
    access_team: str  # Cloudflare Access team domain, e.g. myteam.cloudflareaccess.com
    access_aud: str  # Access application audience (AUD) tag
    retention_days: int

    @property
    def events_dir(self) -> Path:
        return self.claude_dir / "agent-events"

    @property
    def samples_dir(self) -> Path:
        return self.claude_dir / "agent-samples"

    @property
    def state_dir(self) -> Path:
        return self.claude_dir / "agent-state"

    @property
    def access_enabled(self) -> bool:
        return bool(self.access_team and self.access_aud)


def normalize_team(team: str) -> str:
    """'myteam', 'myteam.cloudflareaccess.com' or 'https://myteam.cloudflareaccess.com/' -> host."""
    team = team.strip().removeprefix("https://").removeprefix("http://").strip("/")
    if team and "." not in team:
        team += ".cloudflareaccess.com"
    return team


def load() -> Config:
    home = Path(os.environ.get("HOME", "/config"))
    return Config(
        projects_dir=Path(os.environ.get("PROJECTS_DIR") or os.environ.get("DEFAULT_WORKSPACE") or home / "projects"),
        claude_dir=Path(os.environ.get("AGENT_CLAUDE_DIR", home / ".claude")),
        data_dir=Path(os.environ.get("AGENT_DATA_DIR", home / "agent-dashboard")),
        code_server_url=os.environ.get("CODE_SERVER_URL", "").rstrip("/"),
        access_team=normalize_team(os.environ.get("CF_ACCESS_TEAM_DOMAIN", "")),
        access_aud=os.environ.get("CF_ACCESS_AUD", "").strip(),
        retention_days=int(os.environ.get("AGENT_RETENTION_DAYS", "90")),
    )
