#!/usr/bin/env bash
# =============================================================================
# lib/account.sh — Account lifecycle operations.
# Every function here is callable from both the CLI and the TUI; none of them
# parse argv or print usage. That separation is what made the TUI possible.
# =============================================================================

[[ -n ${_USERS_PRO_ACCOUNT_LOADED:-} ]] && return 0
_USERS_PRO_ACCOUNT_LOADED=1

# =============================================================================
# Create
# =============================================================================

# account_create <username> <shell> <comment> <groups_csv> <ssh_pw_auth>
#                <allow_privileged> [uid] [home] [expire] [sudo_nopasswd]
account_create() {
  local username=$1 shell=${2:-/bin/bash} comment=${3:-} groups_csv=${4:-}
  local ssh_pw_auth=${5:-auto} allow_privileged=${6:-no}
  local want_uid=${7:-} want_home=${8:-} expire=${9:-} sudo_nopasswd=${10:-no}

  validate_username "$username"
  user_exists "$username" && die "-$EX_CONFLICT" "User '$username' already exists."
  validate_shell "$shell"
  [[ ${ssh_pw_auth,,} == auto ]] || ssh_pw_auth=$(normalize_yes_no "$ssh_pw_auth")
  [[ -n $want_uid ]] && validate_uint "$want_uid"
  [[ -n $expire ]] && validate_account_expire_date "$expire"

  local -a groups=()
  mapfile -t groups < <(csv_to_lines "$groups_csv")
  if (( ${#groups[@]} > 0 )); then
    validate_groups_exist "${groups[@]}"
    check_privileged_groups "$allow_privileged" "${groups[@]}"
  fi

  if [[ -n $want_home ]]; then
    is_safe_deletable_path "$want_home" ||
      die "-$EX_DATAERR" "Home path '$want_home' is outside the permitted areas."
  fi

  local -a useradd_cmd=(useradd --create-home --shell "$shell" --user-group)
  [[ -n $comment ]] && useradd_cmd+=(--comment "$comment")
  [[ -n $want_uid ]] && useradd_cmd+=(--uid "$want_uid")
  [[ -n $want_home ]] && useradd_cmd+=(--home-dir "$want_home")
  (( ${#groups[@]} > 0 )) && useradd_cmd+=(--groups "$(join_by_comma "${groups[@]}")")
  useradd_cmd+=(-- "$username")

  log_info "Creating user '${username}'..."
  if ! run_cmd "create user ${username}" "${useradd_cmd[@]}"; then
    PASSWORD=""
    die "-$EX_SOFTWARE" "useradd failed for '${username}'."
  fi

  # --- Everything past this point can leave a half-built account behind, so
  # failures unwind. FIX: the original had no rollback after useradd for the
  # SSH step, stranding a user with no working login path. ---------------------
  local rollback_needed=no

  if [[ -n $PASSWORD ]]; then
    if ! set_user_password "$username"; then
      rollback_needed=yes
      log_error "Failed to set the password for '${username}'."
    fi
  else
    log_warn "No password staged; '${username}' is created with a locked password."
    [[ $DRY_RUN == true ]] || passwd -l -- "$username" >/dev/null 2>&1 || true
  fi

  if [[ $rollback_needed == no && $allow_privileged != yes && $DRY_RUN == false ]]; then
    local g
    local -a actual=()
    read -r -a actual <<<"$(user_groups "$username")"
    for g in "${PRIVILEGED_GROUPS[@]}"; do
      # FIX (CRITICAL): exact membership, not `grep -w`. The old test matched
      # substrings across hyphens, so a user placed in `sudo-admins` was
      # detected as privileged and immediately `userdel --remove`'d.
      if list_contains "$g" "${actual[@]+"${actual[@]}"}"; then
        rollback_needed=yes
        log_error "'${username}' landed in privileged group '${g}' without --allow-privileged."
        break
      fi
    done
  fi

  if [[ $rollback_needed == yes ]]; then
    log_warn "Rolling back creation of '${username}'."
    userdel --remove -- "$username" >/dev/null 2>&1 || true
    remove_ssh_config_for_user "$username" >/dev/null 2>&1 || true
    die "-$EX_SOFTWARE" "User creation rolled back for '${username}'."
  fi

  if [[ -n $expire ]]; then
    run_cmd "set expiry for ${username}" \
      chage --expiredate "$(normalize_expire_date "$expire")" -- "$username" ||
      log_warn "Could not apply the expiry date."
  fi

  if [[ $sudo_nopasswd == yes ]]; then
    account_set_sudo_nopasswd "$username" yes
  fi

  configure_ssh_password_auth "$username" "$ssh_pw_auth"
  [[ $ssh_pw_auth == yes ]] && ensure_ssh_service_active

  audit_write "SUCCESS" "created user ${username} shell=${shell} groups=${groups_csv:-none}"
  log_info "User '${username}' provisioned successfully."
}

# =============================================================================
# Delete
# =============================================================================

backup_home() {
  local username=$1 home=$2 backup_path=$3
  [[ -d $home ]] || { log_warn "Home '$home' not found; skipping backup."; return 0; }
  [[ -e $backup_path ]] && die "-$EX_CONFLICT" "Backup path '$backup_path' already exists."
  require_cmd tar

  local resolved_home resolved_backup parent
  resolved_home=$(realpath -m -- "$home") || die "-$EX_DATAERR" "Cannot resolve '$home'."
  resolved_backup=$(realpath -m -- "$backup_path") || die "-$EX_DATAERR" "Cannot resolve '$backup_path'."
  if [[ $resolved_backup == "$resolved_home" || $resolved_backup == "$resolved_home"/* ]]; then
    die "-$EX_DATAERR" "The backup must not live inside the home directory."
  fi

  if [[ $DRY_RUN == true ]]; then
    log_info "DRY-RUN would archive '${resolved_home}' to '${resolved_backup}'."
    return 0
  fi

  parent=$(dirname -- "$resolved_backup")
  mkdir -p -- "$parent"

  # FIX (SECURITY): the original created the archive under the ambient umask,
  # producing a 0644 tarball of a private home — SSH keys, tokens, history —
  # readable by every account on the box. Created 0600 before any data lands.
  local prev_umask
  prev_umask=$(umask)
  umask 077
  : >"$resolved_backup"
  chmod 0600 -- "$resolved_backup"

  local compress=()
  case $resolved_backup in
    *.tar.gz|*.tgz) compress=(-z) ;;
    *.tar.zst)      compress=(--zstd) ;;
    *.tar.xz)       compress=(-J) ;;
  esac

  if ! tar -cp "${compress[@]+"${compress[@]}"}" -f "$resolved_backup" \
       -C "$(dirname -- "$resolved_home")" -- "$(basename -- "$resolved_home")"; then
    umask "$prev_umask"
    die "-$EX_SOFTWARE" "Backup of '${resolved_home}' failed."
  fi
  umask "$prev_umask"
  chmod 0600 -- "$resolved_backup"
  audit_write "SUCCESS" "backed up ${resolved_home} to ${resolved_backup}"
  log_info "Archived '${home}' to '${resolved_backup}' (mode 0600)."
}

kill_user_processes() {
  local username=$1
  has_cmd pkill || { log_warn "pkill unavailable; cannot terminate processes."; return 0; }
  if [[ $DRY_RUN == true ]]; then
    log_info "DRY-RUN would terminate processes owned by '${username}'."
    return 0
  fi
  pkill -TERM -u "$username" 2>/dev/null || true
  local waited=0
  while (( waited < 5 )); do
    (( $(user_proc_count "$username") == 0 )) && break
    sleep 1
    waited=$((waited + 1))
  done
  pkill -KILL -u "$username" 2>/dev/null || true
  log_info "Terminated processes owned by '${username}'."
}

purge_user_temp_files() {
  local username=$1
  has_cmd find || { log_warn "find unavailable; skipping temp purge."; return 0; }
  if [[ $DRY_RUN == true ]]; then
    log_info "DRY-RUN would purge /tmp and /var/tmp files owned by '${username}'."
    return 0
  fi
  find /tmp /var/tmp -xdev -user "$username" -print0 2>/dev/null |
    xargs -0 -r rm -rf -- 2>/dev/null || true
  log_info "Purged temporary files owned by '${username}'."
}

remove_user_crontab() {
  local username=$1
  has_cmd crontab || return 0
  if [[ $DRY_RUN == true ]]; then
    log_info "DRY-RUN would remove the crontab for '${username}'."
    return 0
  fi
  crontab -u "$username" -r 2>/dev/null || true
}

cleanup_leftover_group() {
  local group=$1 gid members
  group_exists "$group" || return 0
  gid=$(getent group "$group" | awk -F: '{print $3}')
  members=$(getent group "$group" | awk -F: '{print $4}')
  [[ -n $members ]] && return 0
  if getent passwd | awk -F: -v gid="$gid" '$4 == gid { found = 1 } END { exit found ? 0 : 1 }'; then
    return 0
  fi
  run_cmd "delete orphaned group ${group}" groupdel -- "$group" || true
}

account_remove_sudoers() {
  local username=$1
  # NOTE: `local a=$1 b="...$a..."` expands $a as EMPTY (or, worse, picks up a
  # global of the same name) because bash declares every name before assigning.
  # Collapsing these two lines silently pointed the removal at a bogus path,
  # which meant sudo privileges were never actually revoked.
  local file="${SUDOERS_DIR}/90-users-pro-${username}"
  [[ -f $file ]] || return 0
  run_cmd "remove sudoers drop-in for ${username}" rm -f -- "$file"
}

# account_delete <username> <force> <keep_home> <backup_path> <purge_temp>
account_delete() {
  local username=$1 force=${2:-no} keep_home=${3:-no}
  local backup_path=${4:-} purge_temp=${5:-no}

  require_user_exists "$username"
  is_protected_user "$username" && die "-$EX_NOPERM" "Refusing to delete the protected account '${username}'."

  local uid home
  uid=$(user_uid "$username")
  home=$(user_home "$username")

  if (( uid < 1000 )) && [[ $force != yes ]]; then
    die "-$EX_NOPERM" "'${username}' looks like a system account (uid ${uid}). $(hint "Pass --force to override." "Set 'force' to yes in the form to override.")"
  fi
  if is_privileged_user "$username" && [[ $force != yes ]]; then
    die "-$EX_NOPERM" "'${username}' is privileged (member of a privileged group). $(hint "Pass --force to override." "Set 'force' to yes in the form to override.")"
  fi
  if [[ $keep_home == no && -n $home && -d $home ]] && ! is_safe_deletable_path "$home"; then
    die "-$EX_DATAERR" "Home '${home}' is not safe to remove. $(hint "Use --keep-home." "Set 'keep home' to yes in the form.")"
  fi

  [[ -n $backup_path ]] && backup_home "$username" "$home" "$backup_path"

  local proc_count
  proc_count=$(user_proc_count "$username")
  if (( proc_count > 0 )); then
    [[ $force == yes ]] ||
      die "-$EX_CONFLICT" "'${username}' has ${proc_count} running process(es). $(hint "Pass --force to terminate them." "Set 'force' to yes in the form to terminate them.")"
    kill_user_processes "$username"
  fi

  remove_user_crontab "$username"
  account_remove_sudoers "$username"

  if [[ $keep_home == yes && -n $home && -f "${home}/.ssh/authorized_keys" ]]; then
    run_cmd "strip authorized_keys from retained home" rm -f -- "${home}/.ssh/authorized_keys"
  fi

  [[ $purge_temp == yes ]] && purge_user_temp_files "$username"
  remove_ssh_config_for_user "$username"

  if [[ $DRY_RUN == true ]]; then
    log_info "DRY-RUN would delete user '${username}' (keep_home=${keep_home})."
    return 0
  fi

  if [[ $keep_home == no ]]; then
    if ! run_cmd_capture "delete user ${username} with home" userdel --remove -- "$username"; then
      log_warn "userdel --remove reported: ${RUN_OUTPUT}"
      if user_exists "$username"; then
        run_cmd_capture "delete user ${username}" userdel -- "$username" ||
          die "-$EX_SOFTWARE" "userdel failed: ${RUN_OUTPUT}"
      fi
      [[ -n $home && -d $home ]] && safe_rm_rf "$home"
    fi
  else
    run_cmd_capture "delete user ${username} keeping home" userdel -- "$username" ||
      die "-$EX_SOFTWARE" "userdel failed: ${RUN_OUTPUT}"
  fi

  rm -f -- "/var/mail/${username}" "/var/spool/mail/${username}" 2>/dev/null || true
  cleanup_leftover_group "$username"

  audit_write "SUCCESS" "deleted user ${username} keep_home=${keep_home}"
  log_info "User '${username}' deleted."
}

# =============================================================================
# Edit primitives — each is independently callable from the TUI.
# =============================================================================

account_guard_editable() {
  local username=$1 force=${2:-no} uid
  require_user_exists "$username"
  is_protected_user "$username" && die "-$EX_NOPERM" "Refusing to modify the protected account '${username}'."
  uid=$(user_uid "$username")
  if (( uid < 1000 )) && [[ $force != yes ]]; then
    die "-$EX_NOPERM" "'${username}' looks like a system account (uid ${uid}). $(hint "Pass --force to override." "Set 'force' to yes in the form to override.")"
  fi
}

account_lock() {
  local username=$1
  run_cmd "lock account ${username}" passwd -l -- "$username" ||
    die "-$EX_SOFTWARE" "Failed to lock '${username}'."
  log_info "Account '${username}' locked."
}

account_unlock() {
  local username=$1
  if run_cmd "unlock account ${username}" passwd -u -- "$username"; then
    log_info "Account '${username}' unlocked."
    return 0
  fi
  # An account with an empty password field needs -f to unlock.
  run_cmd "force-unlock account ${username}" passwd -u -f -- "$username" ||
    die "-$EX_SOFTWARE" "Failed to unlock '${username}'."
  log_info "Account '${username}' unlocked."
}

account_force_password_change() {
  local username=$1
  run_cmd "force password change for ${username}" chage -d 0 -- "$username" ||
    die "-$EX_SOFTWARE" "Failed to expire the password for '${username}'."
  log_info "'${username}' must change their password at next login."
}

account_set_shell() {
  local username=$1 shell=$2
  validate_shell "$shell"
  run_cmd "set shell ${shell} for ${username}" usermod --shell "$shell" -- "$username" ||
    die "-$EX_SOFTWARE" "Failed to set the shell for '${username}'."
  log_info "Shell for '${username}' set to '${shell}'."
}

account_set_comment() {
  local username=$1 comment=$2
  run_cmd "set comment for ${username}" usermod --comment "$comment" -- "$username" ||
    die "-$EX_SOFTWARE" "Failed to set the comment for '${username}'."
}

account_set_home() {
  local username=$1 new_home=$2 move=${3:-no} primary_group
  is_safe_deletable_path "$new_home" || die "-$EX_DATAERR" "Home path '${new_home}' is not permitted."

  if [[ $move == yes ]]; then
    run_cmd "move home of ${username} to ${new_home}" \
      usermod --move-home --home "$new_home" -- "$username" ||
      die "-$EX_SOFTWARE" "Failed to move the home directory for '${username}'."
  else
    run_cmd "set home of ${username} to ${new_home}" \
      usermod --home "$new_home" -- "$username" ||
      die "-$EX_SOFTWARE" "Failed to set the home directory for '${username}'."

    if [[ $DRY_RUN == false && ! -d $new_home ]]; then
      primary_group=$(id -gn -- "$username")
      install -d -m 0750 -o "$username" -g "$primary_group" -- "$new_home"
      if [[ -d /etc/skel ]]; then
        cp -aT /etc/skel "$new_home" 2>/dev/null || true
        chown -R -- "${username}:${primary_group}" "$new_home"
      fi
    fi
  fi

  if [[ $DRY_RUN == false && -d $new_home ]]; then
    local owner
    owner=$(stat -c '%U' -- "$new_home" 2>/dev/null || true)
    if [[ -n $owner && $owner != "$username" ]]; then
      chown -- "${username}:$(id -gn -- "$username")" "$new_home" 2>/dev/null || true
    fi
  fi
  log_info "Home directory for '${username}' set to '${new_home}'."
}

account_set_expiry() {
  local username=$1 value=$2
  validate_account_expire_date "$value"
  run_cmd "set expiry for ${username}" \
    chage --expiredate "$(normalize_expire_date "$value")" -- "$username" ||
    die "-$EX_SOFTWARE" "Failed to set the expiry date for '${username}'."
  log_info "Expiry for '${username}' set to '${value}'."
}

account_set_aging() {
  local username=$1 min=${2:-} max=${3:-} warn=${4:-} inactive=${5:-}
  local -a args=()
  [[ -n $min ]] && { validate_integer "$min"; args+=(--mindays "$min"); }
  [[ -n $max ]] && { validate_integer "$max"; args+=(--maxdays "$max"); }
  [[ -n $warn ]] && { validate_integer "$warn"; args+=(--warndays "$warn"); }
  [[ -n $inactive ]] && { validate_integer "$inactive"; args+=(--inactive "$inactive"); }
  (( ${#args[@]} > 0 )) || return 0
  run_cmd "set password aging for ${username}" chage "${args[@]}" -- "$username" ||
    die "-$EX_SOFTWARE" "Failed to set password aging for '${username}'."
  log_info "Password aging updated for '${username}'."
}

account_add_groups() {
  local username=$1 allow_privileged=$2
  shift 2
  local -a groups=("$@")
  (( ${#groups[@]} > 0 )) || return 0
  validate_groups_exist "${groups[@]}"
  check_privileged_groups "$allow_privileged" "${groups[@]}"
  run_cmd "add ${username} to ${groups[*]}" \
    usermod --append --groups "$(join_by_comma "${groups[@]}")" -- "$username" ||
    die "-$EX_SOFTWARE" "Failed to add groups for '${username}'."
  log_info "Added '${username}' to: ${groups[*]}"
}

account_remove_groups() {
  local username=$1
  shift
  local -a groups=("$@")
  (( ${#groups[@]} > 0 )) || return 0
  validate_groups_exist "${groups[@]}"
  require_cmd gpasswd

  local primary g
  primary=$(id -gn -- "$username")
  for g in "${groups[@]}"; do
    [[ $g == "$primary" ]] && die "-$EX_DATAERR" "Cannot remove the primary group '${g}'."
    if is_user_in_group "$username" "$g"; then
      run_cmd "remove ${username} from ${g}" gpasswd -d "$username" "$g" ||
        log_warn "Could not remove '${username}' from '${g}'."
    else
      log_debug "'${username}' is not a member of '${g}'; nothing to do."
    fi
  done
  log_info "Removed '${username}' from: ${groups[*]}"
}

account_set_groups() {
  local username=$1 allow_privileged=$2
  shift 2
  local -a groups=("$@")
  if (( ${#groups[@]} == 0 )); then
    account_clear_supplementary_groups "$username"
    return 0
  fi
  validate_groups_exist "${groups[@]}"
  check_privileged_groups "$allow_privileged" "${groups[@]}"
  run_cmd "replace groups of ${username} with ${groups[*]}" \
    usermod --groups "$(join_by_comma "${groups[@]}")" -- "$username" ||
    die "-$EX_SOFTWARE" "Failed to set groups for '${username}'."
  log_info "Supplementary groups for '${username}' set to: ${groups[*]}"
}

account_clear_supplementary_groups() {
  local username=$1
  if run_cmd "clear supplementary groups of ${username}" usermod --groups "" -- "$username"; then
    log_info "Cleared supplementary groups for '${username}'."
    return 0
  fi
  require_cmd gpasswd
  local primary g
  primary=$(id -gn -- "$username")
  local -a current=()
  mapfile -t current < <(user_supplementary_groups "$username")
  for g in "${current[@]+"${current[@]}"}"; do
    [[ $g == "$primary" ]] && continue
    gpasswd -d "$username" "$g" 2>/dev/null || true
  done
  log_info "Cleared supplementary groups for '${username}'."
}

# --- sudo management — NEW --------------------------------------------------
account_set_sudo_nopasswd() {
  local username=$1 enable=$2
  local file="${SUDOERS_DIR}/90-users-pro-${username}"

  if [[ $enable != yes ]]; then
    account_remove_sudoers "$username"
    log_info "Removed the managed sudoers entry for '${username}'."
    return 0
  fi

  [[ -d $SUDOERS_DIR ]] || die "-$EX_CONFIG" "${SUDOERS_DIR} does not exist."
  if [[ $DRY_RUN == true ]]; then
    log_info "DRY-RUN would grant passwordless sudo to '${username}' via ${file}."
    return 0
  fi

  local tmp
  tmp=$(mktemp)
  printf '# Managed by users-pro %s\n%s ALL=(ALL) NOPASSWD: ALL\n' "$USERS_PRO_VERSION" "$username" >"$tmp"
  if has_cmd visudo && ! visudo -c -f "$tmp" >/dev/null 2>&1; then
    rm -f -- "$tmp"
    die "-$EX_CONFIG" "Generated sudoers snippet failed validation."
  fi
  install -m 0440 -o root -g root -- "$tmp" "$file"
  rm -f -- "$tmp"
  audit_write "SUCCESS" "granted passwordless sudo to ${username}"
  log_warn "Granted passwordless sudo to '${username}'. This is a significant privilege."
}

# --- Composite convenience operations for the TUI ---------------------------

account_disable() {
  local username=$1
  account_lock "$username"
  account_set_expiry "$username" "$(date -d 'yesterday' +%Y-%m-%d)"
  account_set_shell "$username" /usr/sbin/nologin
  log_info "Account '${username}' fully disabled (locked, expired, nologin)."
}

account_enable() {
  local username=$1 shell=${2:-/bin/bash}
  account_unlock "$username"
  account_set_expiry "$username" -1
  account_set_shell "$username" "$shell"
  log_info "Account '${username}' re-enabled."
}
