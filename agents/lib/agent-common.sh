# Shared by the agent-* commands (sourced, not run). A project is a folder under
# PROJECTS_DIR, identified by its path relative to it (e.g. "client-x/webshop"); git is
# optional. Its tmux session and Remote Control session share one name derived from that path.

PROJECTS_DIR=${PROJECTS_DIR:-${DEFAULT_WORKSPACE:-}}

die() { echo "$(basename "$0"): $*" >&2; exit 1; }

# FOLDER (relative to PROJECTS_DIR, or absolute inside it) -> REL, ABS
resolve_project() {
  [ -n "$PROJECTS_DIR" ] || die "PROJECTS_DIR is not set"
  local root abs
  root=$(realpath -e "$PROJECTS_DIR") || die "PROJECTS_DIR not found: $PROJECTS_DIR"
  case "$1" in
    /*) abs=$1 ;;
    *) abs=$root/$1 ;;
  esac
  abs=$(realpath -e "$abs" 2>/dev/null) || die "no such folder: $1"
  [ -d "$abs" ] || die "not a folder: $1"
  case "$abs" in
    "$root"/*) ;;
    *) die "not a folder under $root: $1" ;;
  esac
  ABS=$abs
  REL=${abs#"$root"/}
}

# REL -> tmux/Remote Control name: "/", "." and ":" become "_" (tmux rejects "." and ":").
session_name() { local n=${1//\//_}; n=${n//./_}; printf '%s' "${n//:/_}"; }

# NAME -> AGENT_PROJECT recorded in that tmux session (empty if none or no session)
session_project() {
  tmux show-environment -t "=$1" AGENT_PROJECT 2>/dev/null | sed -n 's/^AGENT_PROJECT=//p'
}

has_session() { tmux has-session -t "=$1" 2>/dev/null; }

# NAME -> "running" | "exited" (Claude quit; the pane is kept so its last screen stays readable)
session_state() {
  [ "$(tmux list-panes -t "=$1:" -F '#{pane_dead}' 2>/dev/null | head -n1)" = 1 ] && echo exited || echo running
}
