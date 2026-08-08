#!/usr/bin/env bash
# =============================================================================
# lib/query.sh — Read-only account introspection.
# Shared by the CLI (`info`, `list`) and the TUI detail pane. No mutations here.
# =============================================================================

[[ -n ${_USERS_PRO_QUERY_LOADED:-} ]] && return 0
_USERS_PRO_QUERY_LOADED=1

# --- Field accessors ---------------------------------------------------------

passwd_field() {
  local username=$1 index=$2
  getent passwd -- "$username" | awk -F: -v i="$index" '{print $i}'
}

user_uid()   { passwd_field "$1" 3; }
user_gid()   { passwd_field "$1" 4; }
user_gecos() { passwd_field "$1" 5; }
user_home()  { passwd_field "$1" 6; }
user_shell() { passwd_field "$1" 7; }

user_primary_group() {
  local gid
  gid=$(user_gid "$1")
  [[ -n $gid ]] || return 0
  getent group "$gid" | awk -F: '{print $1}'
}

user_supplementary_groups() {
  local username=$1 primary g
  primary=$(id -gn -- "$username" 2>/dev/null || true)
  local -a groups=()
  read -r -a groups <<<"$(user_groups "$username")"
  for g in "${groups[@]+"${groups[@]}"}"; do
    [[ $g == "$primary" ]] && continue
    printf '%s\n' "$g"
  done
}

# --- Status ------------------------------------------------------------------

# Returns one of: locked, nopass, active, expired, unknown
user_password_status() {
  local username=$1 state
  has_cmd passwd || { printf 'unknown'; return 0; }
  state=$(passwd -S -- "$username" 2>/dev/null | awk '{print $2}')
  case $state in
    L|LK) printf 'locked' ;;
    NP)   printf 'nopass' ;;
    P|PS) printf 'active' ;;
    *)    printf 'unknown' ;;
  esac
}

user_is_locked() { [[ $(user_password_status "$1") == locked ]]; }

user_expiry() {
  local username=$1 value
  has_cmd chage || { printf 'unknown'; return 0; }
  value=$(chage -l -- "$username" 2>/dev/null |
    awk -F: '/Account expires/ {sub(/^[[:space:]]+/, "", $2); print $2; exit}')
  printf '%s' "${value:-never}"
}

user_password_last_change() {
  local username=$1 value
  has_cmd chage || { printf 'unknown'; return 0; }
  value=$(chage -l -- "$username" 2>/dev/null |
    awk -F: '/Last password change/ {sub(/^[[:space:]]+/, "", $2); print $2; exit}')
  printf '%s' "${value:-unknown}"
}

user_is_expired() {
  local expiry epoch now
  expiry=$(user_expiry "$1")
  [[ $expiry == never || $expiry == unknown ]] && return 1
  epoch=$(date -d "$expiry" +%s 2>/dev/null) || return 1
  now=$(date +%s)
  (( epoch < now ))
}

user_proc_count() {
  local username=$1 count=0
  if has_cmd pgrep; then
    # NOTE: `cmd | wc -l || printf 0` double-prints. Under pipefail, pgrep
    # exits 1 when nothing matches, so `wc` emits "0" AND the fallback emits
    # "0" — the caller sees "00", which broke the JSON encoder.
    count=$(pgrep -u "$username" 2>/dev/null | wc -l) || count=0
    count=${count//[^0-9]/}
  fi
  printf '%s' "${count:-0}"
}

user_last_login() {
  local username=$1 line
  if has_cmd lastlog; then
    line=$(lastlog -u "$username" 2>/dev/null | awk 'NR==2 {$1=""; sub(/^[[:space:]]+/,""); print}')
    [[ -n $line ]] && { printf '%s' "$line"; return 0; }
  fi
  if has_cmd last; then
    line=$(last -n 1 -F "$username" 2>/dev/null | head -1)
    [[ -n $line ]] && { printf '%s' "$line"; return 0; }
  fi
  printf 'unknown'
}

user_home_size() {
  local home=$1
  [[ -n $home && -d $home ]] || { printf 'n/a'; return 0; }
  has_cmd du || { printf 'n/a'; return 0; }
  du -sh -- "$home" 2>/dev/null | awk '{print $1}' || printf 'n/a'
}

user_has_sudoers_file() {
  local username=$1
  [[ -f "${SUDOERS_DIR}/90-users-pro-${username}" ]]
}

# A single compact word describing account health, for list rendering.
#
# DISABLED is reported when an account is both locked and expired, which is
# what account_disable produces. Collapsing that to LOCKED misleads: an operator
# unlocks the password, logins still fail because of the expiry, and there is no
# indication why. The distinct label makes the second condition visible.
user_state_label() {
  local username=$1 locked=no expired=no
  user_is_locked "$username" && locked=yes
  user_is_expired "$username" && expired=yes

  if [[ $locked == yes && $expired == yes ]]; then printf 'DISABLED'; return 0; fi
  if [[ $locked == yes ]]; then printf 'LOCKED'; return 0; fi
  if [[ $expired == yes ]]; then printf 'EXPIRED'; return 0; fi
  case $(user_password_status "$username") in
    nopass) printf 'NOPASS' ;;
    active) printf 'ACTIVE' ;;
    *)      printf 'UNKNOWN' ;;
  esac
}

# --- Enumeration -------------------------------------------------------------

# Emits: username:uid:gid:gecos:home:shell
# FIX: the original `$3 >= 1000` filter swept in nobody (65534) and other
# reserved high UIDs. Regular accounts are now bounded by SYS_UID_MAX/UID_MAX.
list_users() {
  local include_system=${1:-no}
  if [[ $include_system == yes ]]; then
    getent passwd | awk -F: '{printf "%s:%s:%s:%s:%s:%s\n", $1, $3, $4, $5, $6, $7}'
  else
    getent passwd | awk -F: '
      ($3 >= 1000 && $3 < 60000) || $1 == "root" {
        printf "%s:%s:%s:%s:%s:%s\n", $1, $3, $4, $5, $6, $7
      }'
  fi
}

list_usernames() { list_users "${1:-no}" | cut -d: -f1; }

list_groups() { getent group | awk -F: '{print $1}' | sort; }

list_shells() {
  if [[ -r /etc/shells ]]; then
    grep -v '^[[:space:]]*#' /etc/shells | grep -v '^[[:space:]]*$'
  fi
  printf '/usr/sbin/nologin\n'
}

# --- Full report -------------------------------------------------------------

section() { printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }

user_report_text() {
  local username=$1 uid gid gecos home shell primary

  uid=$(user_uid "$username")
  gid=$(user_gid "$username")
  gecos=$(user_gecos "$username")
  home=$(user_home "$username")
  shell=$(user_shell "$username")
  primary=$(user_primary_group "$username")

  section "Account Identity"
  printf 'Username         : %s\n' "$username"
  printf 'UID              : %s\n' "$uid"
  printf 'Primary GID      : %s\n' "$gid"
  printf 'Primary group    : %s\n' "${primary:-unknown}"
  printf 'Full name        : %s\n' "${gecos:-}"
  printf 'Home directory   : %s\n' "${home:-}"
  printf 'Shell            : %s\n' "${shell:-}"
  printf 'Supplementary    : %s\n' "$(user_supplementary_groups "$username" | tr '\n' ' ')"
  if is_privileged_user "$username"; then
    printf 'Privileged       : yes (member of a privileged group)\n'
  else
    printf 'Privileged       : no\n'
  fi
  if user_has_sudoers_file "$username"; then
    printf 'Managed sudoers  : %s/90-users-pro-%s\n' "$SUDOERS_DIR" "$username"
  fi

  section "Password and Aging"
  printf 'Status           : %s\n' "$(user_password_status "$username")"
  printf 'Last change      : %s\n' "$(user_password_last_change "$username")"
  printf 'Account expires  : %s\n' "$(user_expiry "$username")"
  has_cmd chage && chage -l -- "$username" 2>/dev/null || true

  section "Login Activity"
  printf 'Last login       : %s\n' "$(user_last_login "$username")"
  if has_cmd last; then
    last -n 5 -F "$username" 2>/dev/null | head -5 || true
  fi

  section "SSH"
  if ssh_installed; then
    local opt val
    for opt in passwordauthentication pubkeyauthentication authenticationmethods \
               maxauthtries permitemptypasswords allowtcpforwarding; do
      val=$(get_effective_ssh_option "$username" "$opt" || true)
      printf '%-22s: %s\n' "$opt" "${val:-unavailable}"
    done
    printf '%-22s: %s\n' "authorized keys" "$(ssh_key_count "$username")"
    local drop_file
    drop_file=$(ssh_dropin_file "$username")
    [[ -f $drop_file ]] && printf '%-22s: %s\n' "drop-in" "$drop_file"
    local fp
    fp=$(ssh_key_fingerprints "$username")
    [[ -n $fp ]] && printf '%s\n' "$fp"
  else
    printf 'openssh-server is not installed.\n'
  fi

  section "Storage"
  printf 'Home size        : %s\n' "$(user_home_size "$home")"

  section "Processes"
  printf 'Active processes : %s\n' "$(user_proc_count "$username")"
  if has_cmd ps; then
    ps -o pid,ppid,etime,cmd -u "$username" 2>/dev/null | head -12 || true
  fi

  section "Cron"
  if has_cmd crontab; then
    crontab -u "$username" -l 2>/dev/null || printf 'No crontab for %s\n' "$username"
  fi

  section "Mail"
  local mailfile="/var/mail/${username}"
  if [[ -f $mailfile ]]; then
    stat -c 'Mail spool size: %s bytes' "$mailfile"
  else
    printf 'No mail spool found.\n'
  fi
}

user_report_json() {
  local username=$1 uid gid gecos home shell primary supp keys
  uid=$(user_uid "$username")
  gid=$(user_gid "$username")
  gecos=$(user_gecos "$username")
  home=$(user_home "$username")
  shell=$(user_shell "$username")
  primary=$(user_primary_group "$username")
  supp=$(user_supplementary_groups "$username" | paste -sd, - 2>/dev/null || true)
  keys=$(ssh_key_count "$username")

  printf '{'
  json_field username "$username";              printf ','
  json_raw_field uid "${uid:-0}";               printf ','
  json_raw_field gid "${gid:-0}";               printf ','
  json_field gecos "$gecos";                    printf ','
  json_field home "$home";                      printf ','
  json_field shell "$shell";                    printf ','
  json_field primary_group "${primary:-}";      printf ','
  json_field supplementary_groups "${supp:-}";  printf ','
  json_field password_status "$(user_password_status "$username")"; printf ','
  json_field expires "$(user_expiry "$username")"; printf ','
  json_field state "$(user_state_label "$username")"; printf ','
  json_raw_field privileged "$(is_privileged_user "$username" && printf true || printf false)"; printf ','
  json_raw_field authorized_keys "${keys:-0}";  printf ','
  json_raw_field processes "$(user_proc_count "$username")"
  printf '}'
}

list_users_json() {
  local include_system=${1:-no} first=1 line username
  printf '['
  while IFS=: read -r username _ _ _ _ _; do
    [[ -n $username ]] || continue
    (( first )) || printf ','
    first=0
    user_report_json "$username"
  done < <(list_users "$include_system")
  printf ']\n'
  unset line
}
