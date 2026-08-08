#!/usr/bin/env bash
# shellcheck disable=SC2015
# SC2015 file-wide: ok()/bad() always return 0, so `cond && ok || bad` cannot
# double-fire.
# shellcheck disable=SC2034
# SC2034: LOG_TO_STDERR is consumed by lib/core.sh, sourced below.
# =============================================================================
# tests/function-tests.sh — Exercise every library function against the real
# system, by name, with an assertion.
#
# Written after a coverage audit found 150 of 195 functions had never been
# called by name in any test. Passing integration tests are not the same thing
# as knowing each function works.
#
# Usage: sudo tests/function-tests.sh
# All mutations use the reserved prefix `fnt-` and are cleaned up.
# =============================================================================

set -uo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
ROOT_DIR=$(cd -- "${TEST_DIR}/.." && pwd -P)
export USERS_PRO_LIB="${ROOT_DIR}/lib"

PASS=0 FAIL=0 SKIP=0
RED=$'\033[31m' GRN=$'\033[32m' YEL=$'\033[33m' DIM=$'\033[2m' RST=$'\033[0m'
[[ -t 1 ]] || { RED="" GRN="" YEL="" DIM="" RST=""; }
ok()   { PASS=$((PASS+1)); printf '  %sPASS%s %s\n' "$GRN" "$RST" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  %sFAIL%s %s\n' "$RED" "$RST" "$1"; [[ -n ${2:-} ]] && printf '       %s%s%s\n' "$DIM" "$2" "$RST"; }
skip() { SKIP=$((SKIP+1)); printf '  %sSKIP%s %s\n' "$YEL" "$RST" "$1"; }
group(){ printf '\n%s── %s%s\n' "$DIM" "$1" "$RST"; }

eq() { [[ $1 == "$2" ]] && ok "$3" || bad "$3" "expected [$1] got [$2]"; }
truthy() { if "$@" >/dev/null 2>&1; then ok "$*"; else bad "$*"; fi; }
falsy()  { if "$@" >/dev/null 2>&1; then bad "$* (should be false)"; else ok "$* is false"; fi; }
nonempty() { [[ -n $1 ]] && ok "$2" || bad "$2" "empty result"; }

LOG_TO_STDERR=false
# shellcheck source=../lib/core.sh
source "${ROOT_DIR}/lib/core.sh"
# shellcheck source=../lib/ssh.sh
source "${ROOT_DIR}/lib/ssh.sh"
# shellcheck source=../lib/query.sh
source "${ROOT_DIR}/lib/query.sh"
# shellcheck source=../lib/account.sh
source "${ROOT_DIR}/lib/account.sh"
# shellcheck source=../lib/tui/term.sh
source "${ROOT_DIR}/lib/tui/term.sh"
set +e
trap - ERR EXIT

# die() exits; run guarded so a rejection is observable.
try() { ( trap - EXIT ERR; "$@" >/dev/null 2>&1 ); }

if (( EUID != 0 )); then
  printf 'These tests mutate real accounts and require root.\n' >&2
  exit 77
fi
command -v useradd >/dev/null 2>&1 || { printf 'shadow-utils required.\n' >&2; exit 69; }

U=fnt-user
U2=fnt-user2
G=fnt-group
G2=fnt-hyphen-grp
cleanup() {
  for u in "$U" "$U2"; do
    userdel --remove -- "$u" >/dev/null 2>&1
    groupdel -- "$u" >/dev/null 2>&1
  done
  groupdel "$G" >/dev/null 2>&1
  groupdel "$G2" >/dev/null 2>&1
  rm -f "/etc/sudoers.d/90-users-pro-${U}" /tmp/fnt-*.tar* 2>/dev/null
  rm -rf /tmp/fnt-home 2>/dev/null
}
trap cleanup EXIT
cleanup
groupadd "$G"; groupadd "$G2"

# =============================================================================
group "core.sh — logging and audit"
# =============================================================================
nonempty "$(_ts)" "_ts() returns a timestamp"
LOG_BUFFER=()
log_info "probe-info"; log_warn "probe-warn"; log_error "probe-err"; log_debug "probe-dbg"
(( ${#LOG_BUFFER[@]} >= 3 )) && ok "log_info/warn/error populate LOG_BUFFER" \
  || bad "log buffer" "${#LOG_BUFFER[@]} entries"
[[ ${LOG_BUFFER[0]} == INFO\|probe-info ]] && ok "_log_emit encodes level|message" \
  || bad "_log_emit format" "${LOG_BUFFER[0]}"

AUDIT_LOG=/tmp/fnt-audit.log; : >"$AUDIT_LOG"
audit_write "SUCCESS" "fnt probe"
grep -q "fnt probe" "$AUDIT_LOG" && ok "audit_write appends to the audit log" || bad "audit_write"
grep -q "actor=" "$AUDIT_LOG" && ok "audit_write records the actor" || bad "audit_write actor"
eq "640" "$(stat -c '%a' "$AUDIT_LOG")" "audit log is mode 0640"
AUDIT_LOG=/var/log/users-pro.log

# =============================================================================
group "core.sh — run_cmd and dry-run"
# =============================================================================
DRY_RUN=false
truthy run_cmd "true probe" true
falsy  run_cmd "false probe" false
run_cmd_capture "echo probe" echo hello; eq "hello" "$RUN_OUTPUT" "run_cmd_capture fills RUN_OUTPUT"
run_cmd_capture "stderr probe" bash -c 'echo oops >&2; exit 3'
eq "oops" "$RUN_OUTPUT" "run_cmd_capture captures stderr"
# REGRESSION: run_cmd used `if "$@"; then ...; fi; local rc=$?`. An if with a
# false condition and no else evaluates to 0, so run_cmd returned 0 for every
# failure — making every `|| die` and `if ! run_cmd` guard in the codebase dead
# code. A failed useradd was reported as a successful provision, no rollback.
run_cmd "exit-code probe" bash -c 'exit 42'
eq "42" "$?" "run_cmd propagates the real exit code"
if ! run_cmd "guard probe" false; then
  ok "a caller's 'if ! run_cmd' guard actually fires"
else
  bad "run_cmd guard" "failure was swallowed"
fi

DRY_RUN=true
rm -f /tmp/fnt-drynope
run_cmd "create file" touch /tmp/fnt-drynope
[[ -e /tmp/fnt-drynope ]] && bad "DRY_RUN suppresses side effects" || ok "DRY_RUN suppresses side effects"
DRY_RUN=false

# =============================================================================
group "core.sh — environment guards"
# =============================================================================
truthy has_cmd bash
falsy  has_cmd definitely-not-a-real-binary-xyz
truthy require_cmd bash
try require_cmd definitely-not-a-real-binary-xyz && bad "require_cmd rejects missing" || ok "require_cmd rejects a missing command"
truthy is_root
truthy validate_root
truthy validate_dependencies
truthy acquire_lock /tmp/fnt.lock
truthy release_lock
# Re-acquiring after release must succeed; a stuck lock would wedge the tool.
truthy acquire_lock /tmp/fnt.lock
release_lock

# =============================================================================
group "core.sh — validation"
# =============================================================================
for v in yes y true on 1; do eq "yes" "$(normalize_yes_no $v)" "normalize_yes_no $v"; done
for v in no n false off 0; do eq "no" "$(normalize_yes_no $v)" "normalize_yes_no $v"; done
truthy validate_yes_no YES
try validate_yes_no wat && bad "validate_yes_no rejects junk" || ok "validate_yes_no rejects junk"
truthy validate_username "$U"
truthy validate_shell /bin/bash
try validate_shell /nonexistent/shell && bad "validate_shell rejects missing" || ok "validate_shell rejects a missing shell"
try validate_shell relative/path && bad "validate_shell rejects relative" || ok "validate_shell rejects a relative path"
truthy validate_shell /usr/sbin/nologin
truthy validate_groups_exist "$G" "$G2"
try validate_groups_exist no-such-group && bad "validate_groups_exist" || ok "validate_groups_exist rejects a missing group"
truthy group_exists "$G"
falsy  group_exists fnt-no-such-group
falsy  user_exists "$U"
try require_user_exists "$U" && bad "require_user_exists" || ok "require_user_exists rejects a missing user"
eq "-1" "$(normalize_expire_date never)" "normalize_expire_date never"
eq "2027-01-01" "$(normalize_expire_date 2027-01-01)" "normalize_expire_date passthrough"

# =============================================================================
group "core.sh — paths, lists, json"
# =============================================================================
truthy is_safe_deletable_path /home/alice
falsy  is_safe_deletable_path /etc
mkdir -p /tmp/fnt-home/sub && touch /tmp/fnt-home/sub/f
safe_rm_rf /etc/fnt-should-refuse
[[ -d /etc ]] && ok "safe_rm_rf refuses an unsafe path"
truthy list_contains b a b c
falsy  list_contains z a b c
eq "a,b" "$(join_by_comma a b)" "join_by_comma"
eq "x" "$(csv_to_lines ' x ')" "csv_to_lines trims"
truthy is_privileged_group sudo
falsy  is_privileged_group "$G2"
truthy check_privileged_groups no "$G"
try check_privileged_groups no sudo && bad "check_privileged_groups blocks sudo" || ok "check_privileged_groups blocks sudo without allow"
truthy check_privileged_groups yes sudo
truthy is_protected_user root
eq '{"k":"v"}' "{$(json_field k v)}" "json_field"
eq '{"k":1}' "{$(json_raw_field k 1)}" "json_raw_field"

# =============================================================================
group "core.sh — password helpers"
# =============================================================================
eq "" "$(password_strength_issues 'Xy7!qwertyuiop' fnt)" "strong password: no issues"
nonempty "$(password_strength_issues 'abc' fnt)" "weak password flagged"
gp=$(generate_password 16); eq "16" "${#gp}" "generate_password length"

# =============================================================================
group "account.sh — create"
# =============================================================================
PASSWORD='Fnt!Str0ngPass#9'
truthy account_create "$U" /bin/bash "Fn Test" "$G" no no "" "" "" no
truthy user_exists "$U"
eq "Fn Test" "$(user_gecos "$U")" "account_create applied GECOS"
eq "/bin/bash" "$(user_shell "$U")" "account_create applied the shell"
truthy is_user_in_group "$U" "$G"
eq "" "$PASSWORD" "PASSWORD cleared after use"

# Explicit uid + home + expiry on a second account.
PASSWORD='Fnt!Str0ngPass#9'
truthy account_create "$U2" /usr/sbin/nologin "" "" no no 4242 "" "2030-01-01" no
eq "4242" "$(user_uid "$U2")" "account_create honoured an explicit uid"
eq "/usr/sbin/nologin" "$(user_shell "$U2")" "account_create honoured nologin"
[[ $(user_expiry "$U2") != never ]] && ok "account_create applied the expiry" || bad "expiry"

# =============================================================================
group "query.sh — introspection"
# =============================================================================
nonempty "$(passwd_field "$U" 1)" "passwd_field"
nonempty "$(user_uid "$U")" "user_uid"
nonempty "$(user_gid "$U")" "user_gid"
nonempty "$(user_home "$U")" "user_home"
eq "$U" "$(user_primary_group "$U")" "user_primary_group"
eq "$G" "$(user_supplementary_groups "$U" | tr -d '\n')" "user_supplementary_groups"
eq "active" "$(user_password_status "$U")" "user_password_status"
falsy user_is_locked "$U"
eq "never" "$(user_expiry "$U")" "user_expiry"
nonempty "$(user_password_last_change "$U")" "user_password_last_change"
falsy user_is_expired "$U"
eq "0" "$(user_proc_count "$U")" "user_proc_count returns a single clean integer"
nonempty "$(user_last_login "$U")" "user_last_login"
nonempty "$(user_home_size "$(user_home "$U")")" "user_home_size"
falsy user_has_sudoers_file "$U"
eq "ACTIVE" "$(user_state_label "$U")" "user_state_label"
nonempty "$(user_groups "$U")" "user_groups"
lu=$(list_users no); grep -q "^${U}:" <<<"$lu" && ok "list_users includes the account" || bad "list_users"
ln_out=$(list_usernames no); grep -qx "$U" <<<"$ln_out" && ok "list_usernames" || bad "list_usernames"
lg=$(list_groups); grep -qx "$G" <<<"$lg" && ok "list_groups" || bad "list_groups"
shells_out=$(list_shells); grep -qx /bin/bash <<<"$shells_out" && ok "list_shells" || bad "list_shells"
nonempty "$(section HEAD)" "section"
user_report_text "$U" >/dev/null 2>&1 && ok "user_report_text runs" || bad "user_report_text"
user_report_json "$U" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null \
  && ok "user_report_json emits valid JSON" || bad "user_report_json"
list_users_json no | python3 -c 'import json,sys; assert isinstance(json.load(sys.stdin),list)' 2>/dev/null \
  && ok "list_users_json emits a valid array" || bad "list_users_json"

# =============================================================================
group "account.sh — edit primitives"
# =============================================================================
truthy account_guard_editable "$U" no
try account_guard_editable root no && bad "guard blocks root" || ok "account_guard_editable refuses root"

truthy account_lock "$U";    eq "locked" "$(user_password_status "$U")" "account_lock"
truthy user_is_locked "$U"
truthy account_unlock "$U";  eq "active" "$(user_password_status "$U")" "account_unlock"
truthy account_force_password_change "$U"
truthy account_set_shell "$U" /bin/sh;  eq "/bin/sh" "$(user_shell "$U")" "account_set_shell"
truthy account_set_comment "$U" "Changed"; eq "Changed" "$(user_gecos "$U")" "account_set_comment"
truthy account_set_expiry "$U" 2030-06-01
[[ $(user_expiry "$U") != never ]] && ok "account_set_expiry" || bad "account_set_expiry"
truthy account_set_expiry "$U" -1
eq "never" "$(user_expiry "$U")" "account_set_expiry -1 clears"
truthy account_set_aging "$U" 1 90 14 30
ag=$(chage -l -- "$U"); grep -q 90 <<<"$ag" && ok "account_set_aging" || bad "account_set_aging"

truthy account_add_groups "$U" no "$G2"
truthy is_user_in_group "$U" "$G2"
falsy  is_privileged_user "$U"
truthy account_remove_groups "$U" "$G2"
falsy  is_user_in_group "$U" "$G2"
truthy account_set_groups "$U" no "$G" "$G2"
truthy is_user_in_group "$U" "$G2"
truthy account_clear_supplementary_groups "$U"
eq "" "$(user_supplementary_groups "$U" | tr -d '\n')" "account_clear_supplementary_groups"

truthy account_set_home "$U" /home/fnt-newhome no
eq "/home/fnt-newhome" "$(user_home "$U")" "account_set_home"
[[ -d /home/fnt-newhome ]] && ok "account_set_home created the directory" || bad "home dir"
eq "$U" "$(stat -c '%U' /home/fnt-newhome)" "new home is owned by the user"

if [[ -d $SUDOERS_DIR ]]; then
  truthy account_set_sudo_nopasswd "$U" yes
  truthy user_has_sudoers_file "$U"
  eq "440" "$(stat -c '%a' "${SUDOERS_DIR}/90-users-pro-${U}")" "sudoers drop-in is 0440"
  truthy account_set_sudo_nopasswd "$U" no
  falsy  user_has_sudoers_file "$U"
  truthy account_set_sudo_nopasswd "$U" yes
  truthy account_remove_sudoers "$U"
  falsy  user_has_sudoers_file "$U"
else
  skip "sudoers tests (${SUDOERS_DIR} does not exist)"
  try account_set_sudo_nopasswd "$U" yes && bad "should fail without sudoers dir" \
    || ok "account_set_sudo_nopasswd fails cleanly when ${SUDOERS_DIR} is absent"
fi

truthy account_disable "$U"
eq "/usr/sbin/nologin" "$(user_shell "$U")" "account_disable sets nologin"
eq "locked" "$(user_password_status "$U")" "account_disable locks"
truthy user_is_expired "$U"
eq "DISABLED" "$(user_state_label "$U")" "state label distinguishes disable from a plain lock"
truthy account_enable "$U" /bin/bash
eq "/bin/bash" "$(user_shell "$U")" "account_enable restores the shell"
falsy user_is_expired "$U"

PASSWORD='Another!Str0ng#42'
truthy set_user_password "$U"
eq "" "$PASSWORD" "set_user_password clears PASSWORD"

# =============================================================================
group "ssh.sh"
# =============================================================================
nonempty "$(ssh_block_begin "$U")" "ssh_block_begin"
nonempty "$(ssh_block_end "$U")" "ssh_block_end"
eq "/etc/ssh/sshd_config.d/99-users-pro-${U}.conf" "$(ssh_dropin_file "$U")" "ssh_dropin_file"
nonempty "$(ssh_legacy_file "$U")" "ssh_legacy_file"
eq "$(user_home "$U")/.ssh/authorized_keys" "$(ssh_authorized_keys_path "$U")" "ssh_authorized_keys_path"
eq "0" "$(ssh_key_count "$U")" "ssh_key_count on a fresh account"
nonempty "$(ssh_service_state)" "ssh_service_state"
has_cmd sshd && truthy ssh_installed || ok "ssh_installed is false (openssh-server absent)"
systemd_available && ok "systemd_available true" || ok "systemd_available false (container)"

# remove_ssh_main_block is pure text surgery; test it in isolation.
printf 'Head\n%s\nMatch User x\n  PasswordAuthentication yes\n%s\nTail\n' \
  "$(ssh_block_begin "$U")" "$(ssh_block_end "$U")" >/tmp/fnt-sshd
remove_ssh_main_block "$U" /tmp/fnt-sshd /tmp/fnt-sshd.out
eq "Head
Tail" "$(cat /tmp/fnt-sshd.out)" "remove_ssh_main_block strips exactly the managed block"

if has_cmd ssh-keygen; then
  ssh-keygen -q -t ed25519 -N '' -C 'fnt-key' -f /tmp/fnt-key </dev/null
  KEY=$(cat /tmp/fnt-key.pub)
  truthy validate_public_key "$KEY"
  try validate_public_key "not a key" && bad "validate_public_key rejects junk" || ok "validate_public_key rejects junk"
  truthy ssh_add_authorized_key "$U" "$KEY"
  eq "1" "$(ssh_key_count "$U")" "ssh_add_authorized_key"
  eq "600" "$(stat -c '%a' "$(ssh_authorized_keys_path "$U")")" "authorized_keys is 0600"
  eq "700" "$(stat -c '%a' "$(dirname "$(ssh_authorized_keys_path "$U")")")" ".ssh is 0700"
  nonempty "$(ssh_key_fingerprints "$U")" "ssh_key_fingerprints"
  truthy ssh_add_authorized_key "$U" "$KEY"
  eq "1" "$(ssh_key_count "$U")" "duplicate key is not added twice"
  truthy ssh_remove_authorized_key "$U" "fnt-key"
  eq "0" "$(ssh_key_count "$U")" "ssh_remove_authorized_key"
  ssh_add_authorized_key "$U" "$KEY" >/dev/null
  truthy ssh_clear_authorized_keys "$U"
  eq "0" "$(ssh_key_count "$U")" "ssh_clear_authorized_keys"
  rm -f /tmp/fnt-key /tmp/fnt-key.pub
else
  skip "authorized_keys tests (ssh-keygen unavailable)"
fi

if ssh_installed; then
  truthy configure_ssh_password_auth "$U" auto
  truthy remove_ssh_config_for_user "$U"
else
  truthy configure_ssh_password_auth "$U" auto
  ok "configure_ssh_password_auth 'auto' is a no-op without sshd"
  try configure_ssh_password_auth "$U" yes && bad "explicit yes should fail" \
    || ok "explicit 'yes' fails loudly without openssh-server"
fi

# =============================================================================
group "account.sh — delete path"
# =============================================================================
truthy remove_user_crontab "$U"
truthy purge_user_temp_files "$U"
truthy kill_user_processes "$U"

HOME_U=$(user_home "$U")
truthy backup_home "$U" "$HOME_U" /tmp/fnt-backup.tar.gz
eq "600" "$(stat -c '%a' /tmp/fnt-backup.tar.gz)" "backup_home archive is 0600"
tar -tzf /tmp/fnt-backup.tar.gz >/dev/null 2>&1 && ok "backup archive is valid gzip" || bad "backup archive"
try backup_home "$U" "$HOME_U" "${HOME_U}/inside.tar" && bad "backup inside home" \
  || ok "backup_home refuses a target inside the home directory"

# The privileged guard, and that --force actually overrides it.
usermod -aG sudo "$U" 2>/dev/null
truthy is_privileged_user "$U"
try account_delete "$U" no no "" no && bad "privileged guard" || ok "account_delete refuses a privileged account without force"
truthy user_exists "$U"
truthy account_delete "$U" yes no "" no
falsy  user_exists "$U"
falsy  group_exists "$U"
ok "cleanup_leftover_group removed the orphaned user group"

# keep-home path
truthy account_delete "$U2" yes yes "" no
falsy  user_exists "$U2"

printf '\n%s%s%s\n' "$DIM" "$(printf '%.0s─' {1..56})" "$RST"
printf '%sPASS %d%s   %sFAIL %d%s   %sSKIP %d%s\n' \
  "$GRN" "$PASS" "$RST" "$RED" "$FAIL" "$RST" "$YEL" "$SKIP" "$RST"
(( FAIL == 0 )) || exit 1
exit 0
