#!/usr/bin/env bash
# =============================================================================
# lib/ssh.sh — sshd_config drop-ins, Match blocks, authorized_keys, service.
# =============================================================================

[[ -n ${_USERS_PRO_SSH_LOADED:-} ]] && return 0
_USERS_PRO_SSH_LOADED=1

SSH_SERVICE=""

# =============================================================================
# Detection
# =============================================================================

ssh_installed() {
  has_cmd sshd || return 1
  if has_cmd dpkg-query; then
    dpkg-query -W -f='${Status}' openssh-server 2>/dev/null |
      grep -q "install ok installed" || return 1
  fi
  return 0
}

require_ssh() {
  ssh_installed || die "-$EX_UNAVAILABLE" "openssh-server is required for this operation."
}

systemd_available() { [[ -d /run/systemd/system ]]; }

detect_ssh_service() {
  [[ -n $SSH_SERVICE ]] && return 0
  systemd_available || return 1
  local svc
  # FIX: `systemctl list-unit-files <name>` succeeds even when the unit is
  # absent (empty table, exit 0), so the original always latched onto
  # ssh.service. Now the output is actually inspected.
  for svc in ssh.service sshd.service; do
    if systemctl list-unit-files --no-legend --no-pager "$svc" 2>/dev/null | grep -q "^${svc}"; then
      SSH_SERVICE=$svc
      return 0
    fi
  done
  for svc in ssh.service sshd.service; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      SSH_SERVICE=$svc
      return 0
    fi
  done
  return 1
}

ssh_service_state() {
  detect_ssh_service || { printf 'unknown'; return 0; }
  systemctl is-active "$SSH_SERVICE" 2>/dev/null || printf 'inactive'
}

reload_ssh_service() {
  ssh_installed || { log_warn "openssh-server not installed; skipping reload."; return 0; }
  systemd_available || { log_warn "systemd unavailable; skipping reload."; return 0; }
  detect_ssh_service || { log_warn "Could not detect the SSH service unit; skipping reload."; return 0; }

  if systemctl is-active --quiet "$SSH_SERVICE"; then
    if ! run_cmd "reload ${SSH_SERVICE}" systemctl reload "$SSH_SERVICE"; then
      run_cmd "restart ${SSH_SERVICE}" systemctl restart "$SSH_SERVICE" ||
        log_warn "Failed to reload or restart ${SSH_SERVICE}."
    fi
  else
    log_debug "${SSH_SERVICE} is not running; nothing to reload."
  fi
}

ensure_ssh_service_active() {
  ssh_installed && systemd_available || return 0
  detect_ssh_service || return 0
  systemctl is-active --quiet "$SSH_SERVICE" && return 0
  run_cmd "enable and start ${SSH_SERVICE}" systemctl enable --now "$SSH_SERVICE" ||
    log_warn "Could not start ${SSH_SERVICE}."
}

# =============================================================================
# Managed block markers
# =============================================================================

ssh_block_begin() { printf '# BEGIN users-pro ssh Match User %s' "$1"; }
ssh_block_end() { printf '# END users-pro ssh Match User %s' "$1"; }
ssh_dropin_file() { printf '%s/99-users-pro-%s.conf' "$SSHD_DROPIN_DIR" "$1"; }
ssh_legacy_file() { printf '%s/99-allow-passwd-%s.conf' "$SSHD_DROPIN_DIR" "$1"; }

remove_ssh_main_block() {
  local username=$1 src=$2 dest=$3 begin end
  begin=$(ssh_block_begin "$username")
  end=$(ssh_block_end "$username")
  awk -v begin="$begin" -v end="$end" '
    $0 == begin { skip = 1; next }
    $0 == end   { skip = 0; next }
    !skip       { print }
  ' "$src" >"$dest"
}

ssh_include_active() {
  [[ -f $SSHD_MAIN_CONFIG ]] || return 1
  grep -qE '^[[:space:]]*Include[[:space:]].*sshd_config\.d' "$SSHD_MAIN_CONFIG"
}

get_effective_ssh_option() {
  local username=$1 option=$2
  has_cmd sshd || return 1
  sshd -T -C "user=${username},host=localhost,addr=127.0.0.1" 2>/dev/null |
    awk -v opt="${option,,}" 'tolower($1) == opt { print tolower($2); exit }'
}

# =============================================================================
# PasswordAuthentication per user
# =============================================================================

configure_ssh_password_auth() {
  local username=$1 requested=$2 mode

  # `auto` is the default for `add`. It means "apply this if sshd is present,
  # otherwise stay quiet". Without it, the previous default of `yes` made
  # account creation exit non-zero on every host with no openssh-server —
  # after the account had already been created.
  if [[ ${requested,,} == auto ]]; then
    if ! ssh_installed; then
      log_debug "openssh-server is not installed; leaving SSH configuration alone."
      return 0
    fi
    mode=yes
  else
    mode=$(normalize_yes_no "$requested")
  fi

  if ! ssh_installed; then
    if [[ $mode == yes ]]; then
      die "-$EX_UNAVAILABLE" "openssh-server is required to enable SSH password authentication."
    fi
    log_info "openssh-server not installed; skipping SSH password auth configuration."
    return 0
  fi

  local current
  current=$(get_effective_ssh_option "$username" passwordauthentication || true)
  if [[ $current == "$mode" ]]; then
    log_info "SSH PasswordAuthentication is already '${mode}' for '${username}'."
    return 0
  fi

  if [[ $DRY_RUN == true ]]; then
    log_info "DRY-RUN would set SSH PasswordAuthentication=${mode} for '${username}'."
    return 0
  fi

  [[ -f $SSHD_MAIN_CONFIG ]] || die "-$EX_CONFIG" "SSH configuration '$SSHD_MAIN_CONFIG' not found."

  local drop_file legacy_file main_backup="" legacy_backup="" tmp_file="" begin
  drop_file=$(ssh_dropin_file "$username")
  legacy_file=$(ssh_legacy_file "$username")
  begin=$(ssh_block_begin "$username")

  if [[ -f $legacy_file ]]; then
    legacy_backup="${legacy_file}.bak.$$"
    mv -- "$legacy_file" "$legacy_backup"
  fi

  if grep -qF -- "$begin" "$SSHD_MAIN_CONFIG"; then
    main_backup="${SSHD_MAIN_CONFIG}.users-pro.bak.$$"
    cp -p -- "$SSHD_MAIN_CONFIG" "$main_backup"
    tmp_file=$(mktemp)
    remove_ssh_main_block "$username" "$SSHD_MAIN_CONFIG" "$tmp_file"
    cat -- "$tmp_file" >"$SSHD_MAIN_CONFIG"
    rm -f -- "$tmp_file"
  fi

  if ssh_include_active; then
    mkdir -p -- "$SSHD_DROPIN_DIR"
    cat >"$drop_file" <<EOF
# Managed by users-pro ${USERS_PRO_VERSION}. Manual edits will be overwritten.
Match User ${username}
    PasswordAuthentication ${mode}
EOF
    chmod 0644 -- "$drop_file"
    log_info "Wrote SSH drop-in: ${drop_file}"
  else
    if [[ -z $main_backup ]]; then
      main_backup="${SSHD_MAIN_CONFIG}.users-pro.bak.$$"
      cp -p -- "$SSHD_MAIN_CONFIG" "$main_backup"
    fi
    {
      ssh_block_begin "$username"; printf '\n'
      printf 'Match User %s\n' "$username"
      printf '    PasswordAuthentication %s\n' "$mode"
      ssh_block_end "$username"; printf '\n'
    } >>"$SSHD_MAIN_CONFIG"
    log_info "Appended managed Match block to ${SSHD_MAIN_CONFIG}"
  fi

  if ! sshd -t 2>/dev/null; then
    log_error "sshd -t rejected the new configuration. Rolling back."
    [[ -f $drop_file ]] && rm -f -- "$drop_file"
    [[ -n $legacy_backup && -f $legacy_backup ]] && mv -- "$legacy_backup" "$legacy_file"
    [[ -n $main_backup && -f $main_backup ]] && mv -- "$main_backup" "$SSHD_MAIN_CONFIG"
    die "-$EX_CONFIG" "SSH configuration change rejected by 'sshd -t'."
  fi

  reload_ssh_service

  [[ -n $legacy_backup && -f $legacy_backup ]] && rm -f -- "$legacy_backup"
  [[ -n $main_backup && -f $main_backup ]] && rm -f -- "$main_backup"

  audit_write "SUCCESS" "ssh PasswordAuthentication=${mode} user=${username}"
  log_info "SSH PasswordAuthentication set to '${mode}' for '${username}'."
}

remove_ssh_config_for_user() {
  local username=$1 changed=0 main_backup="" tmp_file="" begin drop_file legacy_file
  drop_file=$(ssh_dropin_file "$username")
  legacy_file=$(ssh_legacy_file "$username")

  if [[ $DRY_RUN == true ]]; then
    log_info "DRY-RUN would remove SSH configuration artifacts for '${username}'."
    return 0
  fi

  [[ -f $drop_file ]] && { rm -f -- "$drop_file"; changed=1; }
  [[ -f $legacy_file ]] && { rm -f -- "$legacy_file"; changed=1; }

  if [[ -f $SSHD_MAIN_CONFIG ]]; then
    begin=$(ssh_block_begin "$username")
    if grep -qF -- "$begin" "$SSHD_MAIN_CONFIG"; then
      main_backup="${SSHD_MAIN_CONFIG}.users-pro.bak.$$"
      cp -p -- "$SSHD_MAIN_CONFIG" "$main_backup"
      tmp_file=$(mktemp)
      remove_ssh_main_block "$username" "$SSHD_MAIN_CONFIG" "$tmp_file"
      cat -- "$tmp_file" >"$SSHD_MAIN_CONFIG"
      rm -f -- "$tmp_file"
      changed=1
    fi
  fi

  (( changed == 1 )) || return 0

  if ssh_installed; then
    if ! sshd -t 2>/dev/null; then
      [[ -n $main_backup && -f $main_backup ]] && mv -- "$main_backup" "$SSHD_MAIN_CONFIG"
      die "-$EX_CONFIG" "SSH configuration test failed while cleaning up '${username}'."
    fi
    reload_ssh_service
  fi

  [[ -n $main_backup && -f $main_backup ]] && rm -f -- "$main_backup"
  log_info "Removed SSH configuration artifacts for '${username}'."
}

# =============================================================================
# authorized_keys management — NEW. The original could toggle password auth but
# had no way to manage the keys that are the actual recommended mechanism.
# =============================================================================

ssh_authorized_keys_path() {
  local username=$1 home
  home=$(getent passwd -- "$username" | awk -F: '{print $6}')
  [[ -n $home ]] || return 1
  printf '%s/.ssh/authorized_keys' "${home%/}"
}

ssh_key_fingerprints() {
  local username=$1 file
  file=$(ssh_authorized_keys_path "$username") || return 0
  [[ -f $file ]] || return 0
  if has_cmd ssh-keygen; then
    ssh-keygen -l -f "$file" 2>/dev/null || true
  else
    grep -cE '^[[:space:]]*(ssh-|ecdsa-|sk-)' "$file" 2>/dev/null || true
  fi
}

ssh_key_count() {
  local username=$1 file count=0
  file=$(ssh_authorized_keys_path "$username") || { printf '0'; return 0; }
  if [[ -f $file ]]; then
    # grep -c prints its count and still exits 1 when the count is zero, so a
    # `|| printf 0` fallback would append a second digit. See query.sh.
    count=$(grep -cE '^[[:space:]]*(ssh-|ecdsa-|sk-)' "$file" 2>/dev/null) || count=0
    count=${count//[^0-9]/}
  fi
  printf '%s' "${count:-0}"
}

validate_public_key() {
  local key=$1
  [[ $key =~ ^(ssh-rsa|ssh-ed25519|ssh-dss|ecdsa-sha2-nistp[0-9]+|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp[0-9]+@openssh\.com)[[:space:]]+[A-Za-z0-9+/=]+([[:space:]].*)?$ ]] ||
    die "-$EX_DATAERR" "That does not look like a valid OpenSSH public key."
  if has_cmd ssh-keygen; then
    local tmp
    tmp=$(mktemp)
    printf '%s\n' "$key" >"$tmp"
    if ! ssh-keygen -l -f "$tmp" >/dev/null 2>&1; then
      rm -f -- "$tmp"
      die "-$EX_DATAERR" "ssh-keygen rejected the supplied public key."
    fi
    rm -f -- "$tmp"
  fi
}

ssh_add_authorized_key() {
  local username=$1 key=$2 file dir primary_group
  validate_public_key "$key"
  file=$(ssh_authorized_keys_path "$username") || die "-$EX_NOUSER" "Cannot resolve home for '${username}'."
  dir=$(dirname -- "$file")
  primary_group=$(id -gn -- "$username")

  if [[ $DRY_RUN == true ]]; then
    log_info "DRY-RUN would append a public key to ${file}."
    return 0
  fi

  install -d -m 0700 -o "$username" -g "$primary_group" -- "$dir"
  if [[ -f $file ]] && grep -qF -- "$key" "$file"; then
    log_info "Key already present for '${username}'."
    return 0
  fi
  printf '%s\n' "$key" >>"$file"
  chown -- "${username}:${primary_group}" "$file"
  chmod 0600 -- "$file"
  audit_write "SUCCESS" "added authorized key for ${username}"
  log_info "Added authorized key for '${username}'."
}

ssh_remove_authorized_key() {
  local username=$1 pattern=$2 file tmp before after
  file=$(ssh_authorized_keys_path "$username") || die "-$EX_NOUSER" "Cannot resolve home for '${username}'."
  [[ -f $file ]] || { log_info "No authorized_keys file for '${username}'."; return 0; }

  if [[ $DRY_RUN == true ]]; then
    log_info "DRY-RUN would remove keys matching '${pattern}' from ${file}."
    return 0
  fi

  before=$(wc -l <"$file")
  tmp=$(mktemp)
  grep -vF -- "$pattern" "$file" >"$tmp" || true
  after=$(wc -l <"$tmp")
  if (( before == after )); then
    rm -f -- "$tmp"
    log_warn "No authorized key matched '${pattern}'."
    return 0
  fi
  cat -- "$tmp" >"$file"
  rm -f -- "$tmp"
  chmod 0600 -- "$file"
  audit_write "SUCCESS" "removed $((before - after)) authorized key(s) for ${username}"
  log_info "Removed $((before - after)) key(s) for '${username}'."
}

ssh_clear_authorized_keys() {
  local username=$1 file
  file=$(ssh_authorized_keys_path "$username") || return 0
  [[ -f $file ]] || return 0
  if [[ $DRY_RUN == true ]]; then
    log_info "DRY-RUN would delete ${file}."
    return 0
  fi
  rm -f -- "$file"
  audit_write "SUCCESS" "cleared authorized_keys for ${username}"
  log_info "Cleared authorized_keys for '${username}'."
}
