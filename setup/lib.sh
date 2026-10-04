#!/usr/bin/env bash
# Shared helpers for the setup scripts. Sourced, never executed directly.

SETUP_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONF_FILE=$SETUP_DIR/setup.env
DRY_RUN=${DRY_RUN:-0}
ASSUME_YES=${ASSUME_YES:-0}
BRIDGE=virbr-dev
NET_NAME=devnet
POOL_NAME=vmpool

if [ -t 1 ]; then
  C_B=$'\e[1m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_R=$'\e[31m'; C_N=$'\e[0m'
else
  C_B=; C_G=; C_Y=; C_R=; C_N=
fi

step() { printf '\n%s==> %s%s\n' "$C_B" "$*" "$C_N"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %sok%s    %s\n' "$C_G" "$C_N" "$*"; }
warn() { printf '    %sWARN%s  %s\n' "$C_Y" "$C_N" "$*" >&2; }
die()  { printf '%sERROR:%s %s\n' "$C_R" "$C_N" "$*" >&2; exit 1; }
explain() { local l; while IFS= read -r l; do printf '    | %s\n' "$l"; done <<<"$*"; }

# ask VAR "Prompt" "default" "explanation"
# An existing value (environment or setup.env) becomes the default. With --yes or
# without a terminal the default is used without asking.
ask() {
  local var=$1 prompt=$2 def=${3:-} why=${4:-} ans
  [ -z "${!var:-}" ] || def=${!var}
  [ -z "$why" ] || { echo; explain "$why"; }
  if [ "$ASSUME_YES" = 1 ] || [ ! -t 0 ]; then
    [ -n "$def" ] || die "no value for '$prompt' and no terminal to ask"
    printf -v "$var" '%s' "$def"; ok "$prompt: $def"; return 0
  fi
  read -r -p "  $prompt [$def]: " ans
  printf -v "$var" '%s' "${ans:-$def}"
  [ -n "${!var}" ] || die "'$prompt' must not be empty"
}

# ask_secret VAR "Prompt" "explanation": hidden input, asked twice
ask_secret() {
  local var=$1 prompt=$2 why=${3:-} a b
  [ -z "$why" ] || { echo; explain "$why"; }
  if [ "$DRY_RUN" = 1 ] && { [ "$ASSUME_YES" = 1 ] || [ ! -t 0 ]; }; then
    printf -v "$var" '%s' "dry-run-secret"; info "(dry-run: placeholder instead of a secret)"; return 0
  fi
  [ -t 0 ] || die "no terminal for '$prompt'"
  while :; do
    read -rsp "  $prompt: " a; echo
    read -rsp "  repeat: " b; echo
    if [ -n "$a" ] && [ "$a" = "$b" ]; then break; fi
    warn "The entries differ or are empty. Try again."
  done
  printf -v "$var" '%s' "$a"
}

# confirm "question" [y|n]: --yes only answers questions whose default is y
confirm() {
  local q=$1 def=${2:-n} ans
  if [ "$ASSUME_YES" = 1 ] || [ ! -t 0 ]; then [ "$def" = y ]; return; fi
  read -r -p "  $q [$def]: " ans; ans=${ans:-$def}
  case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# confirm_type "question" word: must be typed in full, never auto-confirmed
confirm_type() {
  local q=$1 word=$2 ans
  [ -t 0 ] || return 1
  read -r -p "  $q (type '$word' to continue): " ans
  [ "$ans" = "$word" ]
}

run() { if [ "$DRY_RUN" = 1 ]; then info "[dry-run] $*"; else "$@"; fi; }
q()   { if [ "$DRY_RUN" = 1 ]; then return 1; fi; "$@" >/dev/null 2>&1; }  # quiet state probe

require_sudo() {
  [ "$DRY_RUN" = 1 ] && return 0
  command -v sudo >/dev/null 2>&1 || die "sudo is not installed. As root: apt install -y sudo && usermod -aG sudo $USER, then log in again."
  info "sudo asks for your password once."
  sudo -v || die "sudo failed"
}

# put_file PATH MODE < content: writes only when different; sets CHANGED=1/0
CHANGED=0
put_file() {
  local path=$1 mode=$2 new
  new=$(cat)
  CHANGED=0
  if [ -f "$path" ] && [ "$(cat "$path" 2>/dev/null)" = "$new" ]; then
    info "unchanged: $path"; return 0
  fi
  CHANGED=1
  if [ "$DRY_RUN" = 1 ]; then info "[dry-run] would write $path"; return 0; fi
  if [ -f "$path" ]; then sudo cp -p "$path" "$path.pre-devsetup"; fi
  printf '%s\n' "$new" | sudo tee "$path" >/dev/null
  sudo chmod "$mode" "$path"
  ok "wrote $path"
}

load_conf() { if [ -f "$CONF_FILE" ]; then . "$CONF_FILE"; fi; }

# save_conf VAR...: remember the answers for the next script and for re-runs
save_conf() {
  local v
  if [ "$DRY_RUN" = 1 ]; then info "[dry-run] would save answers to $CONF_FILE"; return 0; fi
  ( umask 077
    { echo "# Answers of the setup scripts; edit freely. Not committed (git-ignored)."
      for v in "$@"; do printf '%s=%q\n' "$v" "${!v}"; done; } > "$CONF_FILE" )
  ok "saved answers to $CONF_FILE"
}
