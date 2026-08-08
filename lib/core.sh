#!/usr/bin/env bash
# =============================================================================
# lib/core.sh — Strict mode, logging, audit trail, validation primitives.
# Sourced by every entry point. Never executed directly.
# Requires: bash >= 4.4
# =============================================================================

# shellcheck disable=SC2034
# SC2034 is suppressed file-wide: this is a sourced library. Constants, exit
# codes and palette variables declared here are consumed by sibling files that
# ShellCheck analyses as separate units, so it cannot see the reference.

[[ -n ${_USERS_PRO_CORE_LOADED:-} ]] && return 0
_USERS_PRO_CORE_LOADED=1

set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true

(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )) || {
  printf 'FATAL: bash >= 4.4 required (found %s)\n' "${BASH_VERSION}" >&2
  exit 78
}

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
umask 077

# --- Constants ---------------------------------------------------------------
USERS_PRO_VERSION="2.2.0"
readonly USERS_PRO_VERSION

readonly AUDIT_LOG_DEFAULT="/var/log/users-pro.log"
readonly LOCK_FILE_DEFAULT="/run/lock/users-pro.lock"
readonly SSHD_MAIN_CONFIG="/etc/ssh/sshd_config"
readonly SSHD_DROPIN_DIR="/etc/ssh/sshd_config.d"
readonly SUDOERS_DIR="/etc/sudoers.d"

# Single source of truth. FIX: the original duplicated this list between
# RESTRICTED_GROUPS and is_privileged_group(), inviting drift.
readonly PRIVILEGED_GROUPS=(sudo admin wheel root adm sudoers)

# Accounts that must never be touched regardless of flags.
readonly PROTECTED_USERS=(root daemon bin sys sync nobody systemd-network systemd-resolve)

# Exit codes — distinct so callers/CI can branch on failure class.
readonly EX_OK=0 EX_USAGE=64 EX_DATAERR=65 EX_NOUSER=67 EX_UNAVAILABLE=69
readonly EX_SOFTWARE=70 EX_NOPERM=77 EX_CONFIG=78 EX_CONFLICT=79

# --- Runtime flags (overridable by entry points) ------------------------------
DRY_RUN=${DRY_RUN:-false}
ASSUME_YES=${ASSUME_YES:-false}
QUIET=${QUIET:-false}
VERBOSE=${VERBOSE:-false}
JSON_OUTPUT=${JSON_OUTPUT:-false}
AUDIT_LOG=${AUDIT_LOG:-$AUDIT_LOG_DEFAULT}
LOG_TO_STDERR=${LOG_TO_STDERR:-true}

# "cli" or "tui". The library is shared by both front ends, so guidance in an
# error message must not name a command-line flag that the TUI user has no way
# to type. hint() renders the right phrasing for the active front end.
UI_CONTEXT=${UI_CONTEXT:-cli}

# Captured log lines, so the TUI can render them instead of scribbling on the
# framebuffer. Entry points flip LOG_TO_STDERR=false to enable capture-only.
declare -a LOG_BUFFER=()

# Secret material. Held only between prompt and consumption.
PASSWORD=""

# =============================================================================
# Logging
# =============================================================================

_ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }

_log_emit() {
  local level=$1 msg=$2 line
  line="[${level}] $(_ts) - ${msg}"
  LOG_BUFFER+=("${level}|${msg}")
  (( ${#LOG_BUFFER[@]} > 500 )) && LOG_BUFFER=("${LOG_BUFFER[@]: -300}")

  if [[ $LOG_TO_STDERR == true ]]; then
    case $level in
      INFO) [[ $QUIET == true ]] || printf '%s\n' "$line" ;;
      DEBUG) [[ $VERBOSE == true ]] && printf '%s\n' "$line" >&2 ;;
      *) printf '%s\n' "$line" >&2 ;;
    esac
  fi
  return 0
}

log_info() { _log_emit INFO "$*"; }
log_warn() { _log_emit WARN "$*"; }
log_error() { _log_emit ERROR "$*"; }
log_debug() { _log_emit DEBUG "$*"; }

die() {
  local code=$EX_SOFTWARE
  if [[ ${1:-} =~ ^-[0-9]+$ ]]; then code=${1#-}; shift; fi
  log_error "$*"
  audit_write "FAILURE" "$*"
  # A die() is a deliberate, already-reported exit. Detaching ERR here stops
  # the diagnostic trap from appending a second, misleading "unhandled failure"
  # line for every rejected argument.
  trap - ERR
  exit "$code"
}

# =============================================================================
# Audit trail — NEW. The original left no forensic record of privileged
# mutations, which is a compliance non-starter for an account-management tool.
# =============================================================================

audit_write() {
  local outcome=$1 detail=$2 actor
  actor="${SUDO_USER:-$(id -un 2>/dev/null || echo unknown)}"

  if has_cmd logger; then
    logger -t users-pro -p authpriv.notice -- \
      "actor=${actor} outcome=${outcome} detail=${detail}" 2>/dev/null || true
  fi

  [[ -w $(dirname -- "$AUDIT_LOG") || -w $AUDIT_LOG ]] 2>/dev/null || return 0
  {
    printf '%s actor=%s pid=%s dry_run=%s outcome=%s detail=%s\n' \
      "$(_ts)" "$actor" "$$" "$DRY_RUN" "$outcome" "$detail"
  } >>"$AUDIT_LOG" 2>/dev/null || true
  chmod 0640 -- "$AUDIT_LOG" 2>/dev/null || true
  return 0
}

# =============================================================================
# Execution wrapper — gives every mutation a --dry-run path for free.
# =============================================================================

run_cmd() {
  local desc=$1; shift
  if [[ $DRY_RUN == true ]]; then
    log_info "DRY-RUN would execute: ${desc}"
    log_debug "  -> $*"
    return 0
  fi
  log_debug "exec: $*"
  # NOTE: do not write this as `if "$@"; then ...; fi; local rc=$?`. An `if`
  # whose condition is false and which has no `else` evaluates to 0, so after
  # `fi` the value of $? is the status of the *if statement*, not of the command.
  # (`local rc=$?` is fine on its own — $? expands before local runs. The bug is
  # the if-without-else, not the local.) That shape made run_cmd return 0 for
  # every failure, turning every `|| die` and `if ! run_cmd` guard in this
  # codebase into dead code: a failed useradd was reported as a successful
  # provision, with no rollback.
  local rc=0
  "$@" || rc=$?
  if (( rc == 0 )); then
    audit_write "SUCCESS" "$desc"
  else
    audit_write "FAILURE" "${desc} (rc=${rc})"
  fi
  return "$rc"
}

# Same, but captures combined output into the global RUN_OUTPUT.
RUN_OUTPUT=""
run_cmd_capture() {
  local desc=$1; shift
  RUN_OUTPUT=""
  if [[ $DRY_RUN == true ]]; then
    log_info "DRY-RUN would execute: ${desc}"
    return 0
  fi
  local rc=0
  RUN_OUTPUT=$("$@" 2>&1) || rc=$?
  if (( rc == 0 )); then
    audit_write "SUCCESS" "$desc"
  else
    audit_write "FAILURE" "${desc} (rc=${rc})"
  fi
  return "$rc"
}

# =============================================================================
# Environment guards
# =============================================================================

# hint <cli-phrasing> <tui-phrasing>
hint() {
  if [[ ${UI_CONTEXT:-cli} == tui ]]; then printf '%s' "$2"; else printf '%s' "$1"; fi
}

has_cmd() { command -v -- "$1" >/dev/null 2>&1; }
require_cmd() { has_cmd "$1" || die "-$EX_UNAVAILABLE" "Required command '$1' is not available."; }

is_root() { (( EUID == 0 )); }
validate_root() { is_root || die "-$EX_NOPERM" "This operation requires root privileges."; }

validate_dependencies() {
  local -a required_cmds=(
    useradd userdel usermod groupdel chpasswd getent passwd chage gpasswd
    awk grep sed stat mkdir chmod chown realpath date id tar install
    mktemp cat cp mv rm cut tr wc
  )
  local -a missing=() cmd
  for cmd in "${required_cmds[@]}"; do
    has_cmd "$cmd" || missing+=("$cmd")
  done
  (( ${#missing[@]} == 0 )) || die "-$EX_UNAVAILABLE" "Missing required commands: ${missing[*]}"

  # FIX: original hard-pinned Ubuntu 26.04 with an exact-string grep that
  # would warn on 26.04.1 point releases. Now matches the major series.
  if [[ -r /etc/os-release ]]; then
    local id="" version_id="" pretty=""
    id=$(awk -F= '$1=="ID"{gsub(/"/,"",$2); print $2}' /etc/os-release)
    version_id=$(awk -F= '$1=="VERSION_ID"{gsub(/"/,"",$2); print $2}' /etc/os-release)
    pretty=$(awk -F= '$1=="PRETTY_NAME"{gsub(/"/,"",$2); print substr($0, index($0,"=")+1)}' /etc/os-release)
    pretty=${pretty//\"/}
    if [[ $id != ubuntu || $version_id != 26.04* ]]; then
      log_debug "Tuned for Ubuntu 26.04 LTS. Detected: ${pretty:-unknown}."
    fi
  fi
}

# --- Concurrency lock — NEW. Two simultaneous edits to /etc/passwd or
# sshd_config could interleave and corrupt state. -----------------------------
_LOCK_FD=""
acquire_lock() {
  has_cmd flock || { log_debug "flock unavailable; continuing without lock."; return 0; }
  local lock=${1:-$LOCK_FILE_DEFAULT}
  mkdir -p -- "$(dirname -- "$lock")" 2>/dev/null || return 0
  exec {_LOCK_FD}>"$lock" 2>/dev/null || return 0
  if ! flock -w 10 "$_LOCK_FD"; then
    die "-$EX_CONFLICT" "Another users-pro instance holds the lock ($lock). Try again shortly."
  fi
  log_debug "Acquired lock: $lock"
}
release_lock() {
  [[ -n $_LOCK_FD ]] || return 0
  flock -u "$_LOCK_FD" 2>/dev/null || true
  exec {_LOCK_FD}>&- 2>/dev/null || true
  _LOCK_FD=""
}

# =============================================================================
# Validation
# =============================================================================

normalize_yes_no() {
  # FIX: the original validated case-insensitively but then compared the raw
  # value against a lowercase literal, so `--ssh-password-auth YES` passed
  # validation and then silently did nothing. Callers now use the echoed value.
  local val=${1:-}
  case ${val,,} in
    yes|y|true|on|1) printf 'yes' ;;
    no|n|false|off|0) printf 'no' ;;
    *) die "-$EX_DATAERR" "Expected 'yes' or 'no', got '${val}'." ;;
  esac
}

validate_yes_no() { normalize_yes_no "$1" >/dev/null; }

validate_username() {
  local username=${1:-}
  [[ -n $username ]] || die "-$EX_DATAERR" "Username cannot be empty."
  if (( ${#username} > 32 )); then
    die "-$EX_DATAERR" "Username '$username' exceeds 32 characters."
  fi
  # FIX: original permitted a trailing hyphen, which useradd rejects late and
  # noisily; and permitted an all-numeric tail that confuses shadow tooling.
  if [[ ! $username =~ ^[a-z_][a-z0-9_-]*[a-z0-9_]$ && ! $username =~ ^[a-z_]$ ]]; then
    die "-$EX_DATAERR" "Invalid username '$username'. Lowercase letters, digits, underscore and hyphen; must start with a letter or underscore and must not end with a hyphen."
  fi
}

is_protected_user() {
  local u=$1 p
  for p in "${PROTECTED_USERS[@]}"; do
    [[ $u == "$p" ]] && return 0
  done
  return 1
}

user_exists() { getent passwd -- "$1" >/dev/null 2>&1; }
group_exists() { getent group -- "$1" >/dev/null 2>&1; }

require_user_exists() {
  user_exists "$1" || die "-$EX_NOUSER" "User '$1' does not exist."
}

validate_shell() {
  local shell=${1:-}
  [[ -n $shell ]] || die "-$EX_DATAERR" "Login shell cannot be empty."
  case $shell in
    /usr/sbin/nologin|/sbin/nologin|/bin/false|/usr/bin/false) return 0 ;;
  esac
  [[ $shell == /* ]] || die "-$EX_DATAERR" "Shell must be an absolute path: '$shell'."
  [[ -x $shell ]] || die "-$EX_DATAERR" "Shell '$shell' does not exist or is not executable."
  if [[ -r /etc/shells ]] && ! grep -qFx -- "$shell" /etc/shells; then
    die "-$EX_DATAERR" "Shell '$shell' is not listed in /etc/shells."
  fi
}

validate_integer() {
  [[ ${1:-} =~ ^-?[0-9]+$ ]] || die "-$EX_DATAERR" "Expected an integer, got '${1:-}'."
}

validate_uint() {
  [[ ${1:-} =~ ^[0-9]+$ ]] || die "-$EX_DATAERR" "Expected a non-negative integer, got '${1:-}'."
}

validate_account_expire_date() {
  local value=${1:-}
  case ${value,,} in
    -1|none|clear|disabled|never) return 0 ;;
  esac
  [[ $value =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "-$EX_DATAERR" "Date must be YYYY-MM-DD, or -1/none to clear."
  date -d "$value" >/dev/null 2>&1 || die "-$EX_DATAERR" "Invalid calendar date: $value"
}

normalize_expire_date() {
  case ${1,,} in
    -1|none|clear|disabled|never) printf -- '-1' ;;
    *) printf '%s' "$1" ;;
  esac
}

# =============================================================================
# Path safety
# =============================================================================

is_safe_deletable_path() {
  local path=${1:-} resolved
  [[ -n $path ]] || return 1
  resolved=$(realpath -m -- "$path" 2>/dev/null) || return 1
  [[ $resolved == /* ]] || return 1
  [[ $resolved == "/" ]] && return 1
  [[ $resolved == "/home" || $resolved == "/root" || $resolved == "/var/home" ]] && return 1
  [[ $resolved == /home/*/* ]] && return 0
  [[ $resolved == /home/* ]] && return 0
  [[ $resolved == /var/home/* ]] && return 0

  local IFS='/' part count=0
  local -a parts=()
  read -r -a parts <<<"$resolved"
  for part in "${parts[@]}"; do [[ -n $part ]] && count=$((count + 1)); done
  (( count >= 2 )) || return 1

  case $resolved in
    /bin|/bin/*|/boot|/boot/*|/dev|/dev/*|/etc|/etc/*|/lib|/lib/*|/lib32|/lib32/*|/lib64|/lib64/*|\
    /proc|/proc/*|/run|/run/*|/sbin|/sbin/*|/sys|/sys/*|/usr|/usr/*|/var|/var/*|/tmp|/tmp/*|\
    /snap|/snap/*|/root/*)
      return 1 ;;
  esac
  return 0
}

safe_rm_rf() {
  local path=${1:-} resolved
  [[ -n $path ]] || return 0
  resolved=$(realpath -m -- "$path" 2>/dev/null) || return 0
  if ! is_safe_deletable_path "$resolved"; then
    log_warn "Refusing to remove unsafe path: $resolved"
    return 0
  fi
  run_cmd "remove directory ${resolved}" rm -rf -- "$resolved"
}

# =============================================================================
# List / group helpers
# =============================================================================

csv_to_lines() {
  local csv=${1:-} item
  local -a fields=()
  [[ -n $csv ]] || return 0
  IFS=',' read -r -a fields <<<"$csv"
  for item in "${fields[@]}"; do
    item="${item//[[:space:]]/}"
    [[ -n $item ]] && printf '%s\n' "$item"
  done
  return 0
}

join_by_comma() {
  local IFS=','
  printf '%s' "$*"
}

# FIX (CRITICAL): the original used `grep -qw` against a space-separated group
# list. Hyphens are not word characters, so membership in `sudo-admins` matched
# a test for `sudo` — and in cmd_add that false positive triggered
# `userdel --remove` on a user who had just been created. This is exact-match.
list_contains() {
  local needle=$1 item
  shift
  for item in "$@"; do
    [[ $item == "$needle" ]] && return 0
  done
  return 1
}

user_groups() {
  id -nG -- "$1" 2>/dev/null || true
}

is_user_in_group() {
  local username=$1 group=$2
  local -a groups=()
  read -r -a groups <<<"$(user_groups "$username")"
  list_contains "$group" "${groups[@]+"${groups[@]}"}"
}

validate_groups_exist() {
  local g
  for g in "$@"; do
    group_exists "$g" || die "-$EX_DATAERR" "Group '$g' does not exist."
  done
}

is_privileged_group() {
  list_contains "$1" "${PRIVILEGED_GROUPS[@]}"
}

check_privileged_groups() {
  local allow=$1 g
  shift
  [[ $allow == yes ]] && return 0
  for g in "$@"; do
    if is_privileged_group "$g"; then
      die "-$EX_NOPERM" "Group '$g' is privileged. $(hint "Pass --allow-privileged to assign it deliberately." "Set 'allow privileged' to yes in the form to assign it deliberately.")"
    fi
  done
}

is_privileged_user() {
  local username=$1 g
  local -a groups=()
  read -r -a groups <<<"$(user_groups "$username")"
  for g in "${PRIVILEGED_GROUPS[@]}"; do
    list_contains "$g" "${groups[@]+"${groups[@]}"}" && return 0
  done
  return 1
}

# =============================================================================
# Password handling
# =============================================================================

password_strength_issues() {
  local pw=$1 user=$2
  local -a issues=()
  (( ${#pw} >= 12 )) || issues+=("shorter than 12 characters")
  [[ $pw =~ [A-Z] ]] || issues+=("no uppercase letter")
  [[ $pw =~ [a-z] ]] || issues+=("no lowercase letter")
  [[ $pw =~ [0-9] ]] || issues+=("no digit")
  [[ $pw =~ [^a-zA-Z0-9] ]] || issues+=("no symbol")
  [[ -n $user && ${pw,,} == *"${user,,}"* ]] && issues+=("contains the username")
  printf '%s\n' "${issues[@]+"${issues[@]}"}"
}

generate_password() {
  local length=${1:-20}
  local pw=""
  if [[ -r /dev/urandom ]]; then
    pw=$(LC_ALL=C tr -dc 'A-Za-z0-9!@#%^*_+=-' </dev/urandom 2>/dev/null | head -c "$length" || true)
  fi
  if (( ${#pw} < length )) && has_cmd openssl; then
    pw=$(openssl rand -base64 48 2>/dev/null | tr -d '\n/+=' | head -c "$length")
  fi
  (( ${#pw} >= 8 )) || die "-$EX_UNAVAILABLE" "Unable to generate a password (no entropy source)."
  printf '%s' "$pw"
}

# Reads a password into the global PASSWORD. Supports non-interactive stdin.
prompt_password() {
  local username=$1 pw="" confirm="" strict=${2:-true}

  if [[ ${PASSWORD_FROM_STDIN:-false} == true ]]; then
    IFS= read -r pw || die "-$EX_DATAERR" "Failed to read password from stdin."
    [[ -n $pw ]] || die "-$EX_DATAERR" "Password on stdin was empty."
    PASSWORD=$pw
    return 0
  fi

  # FIX: with `set -e`, a failing `read` (EOF / Ctrl-D) previously aborted the
  # script mid-loop with no message. Failures are now explicit.
  [[ -t 0 ]] || die "-$EX_USAGE" "Interactive terminal required. Use --password-stdin for automation."

  while true; do
    if ! IFS= read -r -s -p "Password for '$username': " pw; then
      printf '\n' >&2
      die "-$EX_USAGE" "Password entry aborted."
    fi
    printf '\n' >&2
    if ! IFS= read -r -s -p "Confirm password: " confirm; then
      printf '\n' >&2
      die "-$EX_USAGE" "Password entry aborted."
    fi
    printf '\n' >&2

    if [[ $pw != "$confirm" ]]; then
      log_error "Passwords do not match."
      continue
    fi
    if (( ${#pw} < 8 )); then
      log_error "Password must be at least 8 characters."
      continue
    fi

    local -a issues=()
    mapfile -t issues < <(password_strength_issues "$pw" "$username")
    if (( ${#issues[@]} > 0 )); then
      local i
      for i in "${issues[@]}"; do log_warn "Weak password: $i"; done
      if [[ $strict == true && $ASSUME_YES != true ]]; then
        local answer=""
        read -r -p "Use it anyway? [y/N] " answer </dev/tty || answer=n
        [[ ${answer,,} == y* ]] || continue
      fi
    fi

    PASSWORD=$pw
    pw="" confirm=""
    return 0
  done
}

set_user_password() {
  local username=$1
  [[ -n $PASSWORD ]] || die "-$EX_SOFTWARE" "set_user_password called with no password staged."
  if [[ $DRY_RUN == true ]]; then
    log_info "DRY-RUN would set password for '${username}'."
    PASSWORD=""
    return 0
  fi
  # printf is a builtin, so the secret never appears in /proc/*/cmdline.
  if ! printf '%s:%s\n' "$username" "$PASSWORD" | chpasswd; then
    PASSWORD=""
    audit_write "FAILURE" "set password for ${username}"
    return 1
  fi
  PASSWORD=""
  audit_write "SUCCESS" "set password for ${username}"
  log_info "Password updated for '${username}'."
}

# =============================================================================
# Confirmation
# =============================================================================

confirm() {
  local prompt=$1 answer=""
  [[ $ASSUME_YES == true ]] && return 0
  [[ -t 0 ]] || die "-$EX_USAGE" "Confirmation required but stdin is not a terminal. Use --yes."
  read -r -p "${prompt} [y/N] " answer </dev/tty || answer=n
  [[ ${answer,,} == y* ]]
}

# =============================================================================
# JSON helper — dependency-free string escaping.
# =============================================================================

json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

json_field() { printf '"%s":"%s"' "$(json_escape "$1")" "$(json_escape "$2")"; }
json_raw_field() { printf '"%s":%s' "$(json_escape "$1")" "$2"; }

# =============================================================================
# Shared cleanup
# =============================================================================

core_cleanup() {
  local exit_code=$?
  # Detach ERR first: returning a non-zero status from an EXIT handler would
  # otherwise re-trigger the diagnostic trap during teardown.
  trap - ERR
  PASSWORD=""
  release_lock
  exit "$exit_code"
}
