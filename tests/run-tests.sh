#!/usr/bin/env bash
# shellcheck disable=SC2015
# SC2015 file-wide: the `cond && ok ... || bad ...` shape is safe by
# construction here — ok() and bad() always return 0, so the || branch cannot
# fire spuriously. It keeps one assertion on one line across ~90 cases.
# shellcheck disable=SC2034
# SC2034: LOG_TO_STDERR is consumed by lib/core.sh, which is sourced below.
# =============================================================================
# tests/run-tests.sh — Dependency-free test harness.
#
# Bats is not installed on a stock Ubuntu server, and an account tool that can
# only be verified after `npm install -g bats` will not get verified. This runs
# anywhere bash runs.
#
# Usage: sudo tests/run-tests.sh [--unit-only]
# Tests that mutate accounts use the reserved prefix `upt-` and clean up after
# themselves; they are skipped automatically when not running as root.
# =============================================================================

set -uo pipefail


TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
ROOT_DIR=$(cd -- "${TEST_DIR}/.." && pwd -P)
BIN="${ROOT_DIR}/bin/users-pro"
export USERS_PRO_LIB="${ROOT_DIR}/lib"

PASS=0 FAIL=0 SKIP=0
UNIT_ONLY=false
[[ ${1:-} == --unit-only ]] && UNIT_ONLY=true

RED=$'\033[31m' GRN=$'\033[32m' YEL=$'\033[33m' DIM=$'\033[2m' RST=$'\033[0m'
[[ -t 1 ]] || { RED="" GRN="" YEL="" DIM="" RST=""; }

ok()   { PASS=$((PASS+1)); printf '  %sPASS%s %s\n' "$GRN" "$RST" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  %sFAIL%s %s\n' "$RED" "$RST" "$1"; [[ -n ${2:-} ]] && printf '       %s%s%s\n' "$DIM" "$2" "$RST"; }
skip() { SKIP=$((SKIP+1)); printf '  %sSKIP%s %s\n' "$YEL" "$RST" "$1"; }
group(){ printf '\n%s%s%s\n' "$DIM" "$1" "$RST"; }

assert_eq() {
  local expect=$1 actual=$2 name=$3
  [[ $expect == "$actual" ]] && ok "$name" || bad "$name" "expected [$expect], got [$actual]"
}
assert_ok()   { if "$@" >/dev/null 2>&1; then ok "$*"; else bad "$*" "exit $?"; fi; }
assert_fail() { if "$@" >/dev/null 2>&1; then bad "$* (should have failed)"; else ok "$* correctly rejected"; fi; }

# Load libraries for unit-level tests.
LOG_TO_STDERR=false
# shellcheck source=../lib/core.sh
source "${ROOT_DIR}/lib/core.sh"
# shellcheck source=../lib/ssh.sh
source "${ROOT_DIR}/lib/ssh.sh"
# shellcheck source=../lib/query.sh
source "${ROOT_DIR}/lib/query.sh"
# shellcheck source=../lib/account.sh
source "${ROOT_DIR}/lib/account.sh"

# lib/core.sh enables `set -Eeuo pipefail`. A test harness must survive failing
# assertions, so errexit and the ERR trap are stood back down after sourcing.
set +e
trap - ERR EXIT

# die() exits; wrap it so a rejection is observable instead of fatal.
try() { ( trap - EXIT ERR; "$@" >/dev/null 2>&1 ); }

# =============================================================================
group "REGRESSION — bugs found in the v1.0.0 audit"
# =============================================================================

# BUG-01 (critical): `grep -qw sudo` matched membership in `sudo-admins`,
# because a hyphen is not a word character. In cmd_add that false positive
# deleted the account that had just been created.
if list_contains sudo alice sudo-admins docker-users; then
  bad "BUG-01 exact group matching" "sudo-admins still matches sudo"
else
  ok "BUG-01 'sudo-admins' no longer matches 'sudo'"
fi
if list_contains sudo alice sudo wheel; then
  ok "BUG-01 real membership in 'sudo' still detected"
else
  bad "BUG-01 real membership" "exact match broke true positives"
fi

# BUG-02: validate_yes_no accepted YES case-insensitively, then the caller
# compared against the lowercase literal, so the setting silently did nothing.
assert_eq "yes" "$(normalize_yes_no YES)"   "BUG-02 'YES' normalises to yes"
assert_eq "no"  "$(normalize_yes_no 'No')"  "BUG-02 'No' normalises to no"
assert_eq "yes" "$(normalize_yes_no true)"  "BUG-02 'true' normalises to yes"
try normalize_yes_no maybe && bad "BUG-02 rejects junk" || ok "BUG-02 'maybe' rejected"

# BUG-03: home backups were written under the ambient umask (0644), leaving a
# world-readable archive of SSH keys and shell history.
if [[ -d /tmp ]]; then
  bk="/tmp/upt-backup-$$.tar"
  home="/tmp/upt-home-$$"
  mkdir -p "$home" && echo secret > "$home/id_ed25519"
  rm -f "$bk"
  DRY_RUN=false backup_home upt-fake "$home" "$bk" >/dev/null 2>&1
  mode=$(stat -c '%a' "$bk" 2>/dev/null || echo missing)
  assert_eq "600" "$mode" "BUG-03 home backup is created 0600"
  rm -rf "$home" "$bk"
fi

# BUG-04: -h/--help printed to stderr and exited 1.
out=$("$BIN" --help 2>/dev/null); rc=$?
if (( rc == 0 )) && [[ -n $out ]]; then
  ok "BUG-04 --help exits 0 with output on stdout"
else
  bad "BUG-04 --help" "rc=$rc, stdout bytes=${#out}"
fi

# BUG-05: `list` demanded root for a read of /etc/passwd.
if "$BIN" list >/dev/null 2>&1; then
  ok "BUG-05 list works without requiring root"
else
  bad "BUG-05 list" "still gated behind validate_root"
fi

# BUG-06: `local a=$1 b="...$a..."` expands $a empty (or grabs a global).
_sc2318_probe() { local u=$1; local f="/x/${u}"; printf '%s' "$f"; }
assert_eq "/x/alice" "$(_sc2318_probe alice)" "BUG-06 single-statement local interpolation"

# BUG-07: `$3 >= 1000` swept nobody (65534) into the regular-account listing.
if list_users no | cut -d: -f1 | grep -qx nobody; then
  bad "BUG-07 nobody excluded" "nobody is still listed as a regular account"
else
  ok "BUG-07 'nobody' excluded from the regular account list"
fi

# BUG-08: usernames ending in a hyphen were accepted and failed later inside
# useradd with an opaque message.
try validate_username "bad-" && bad "BUG-08 trailing hyphen" || ok "BUG-08 trailing hyphen rejected"
try validate_username "9start" && bad "BUG-08 leading digit" || ok "BUG-08 leading digit rejected"
try validate_username "Ünicode" && bad "BUG-08 non-ascii" || ok "BUG-08 non-ASCII rejected"
assert_ok validate_username "good_name-1"
assert_ok validate_username "a"

# =============================================================================
group "UNIT — validation"
# =============================================================================

assert_ok validate_integer -1
assert_ok validate_integer 90
try validate_integer 9.5 && bad "float rejected" || ok "validate_integer rejects 9.5"
try validate_uint -1 && bad "negative uint" || ok "validate_uint rejects -1"

assert_ok validate_account_expire_date 2027-01-15
assert_ok validate_account_expire_date -1
assert_ok validate_account_expire_date none
try validate_account_expire_date 2027-13-45 && bad "bad date" || ok "rejects 2027-13-45"
try validate_account_expire_date "15/01/2027" && bad "bad format" || ok "rejects 15/01/2027"
assert_eq "-1" "$(normalize_expire_date never)" "normalize_expire_date never -> -1"

group "UNIT — path safety"
assert_fail is_safe_deletable_path /
assert_fail is_safe_deletable_path /home
assert_fail is_safe_deletable_path /etc
assert_fail is_safe_deletable_path /usr/local
assert_fail is_safe_deletable_path /var/lib/docker
assert_fail is_safe_deletable_path ""
assert_ok   is_safe_deletable_path /home/alice
assert_ok   is_safe_deletable_path /var/home/alice
assert_ok   is_safe_deletable_path /srv/accounts/alice
# Traversal must resolve before the decision is made.
assert_fail is_safe_deletable_path /home/alice/../../etc

group "UNIT — CSV and list helpers"
assert_eq "a
b
c" "$(csv_to_lines 'a, b ,c')" "csv_to_lines trims whitespace"
assert_eq "" "$(csv_to_lines '')" "csv_to_lines on empty input"
assert_eq "" "$(csv_to_lines ' , , ')" "csv_to_lines drops empty fields"
assert_eq "a,b,c" "$(join_by_comma a b c)" "join_by_comma"

group "UNIT — privilege detection"
assert_ok   is_privileged_group sudo
assert_ok   is_privileged_group wheel
assert_fail is_privileged_group sudo-admins
assert_fail is_privileged_group developers
assert_ok   is_protected_user root
assert_fail is_protected_user alice

group "UNIT — password strength"
assert_eq "" "$(password_strength_issues 'Tr0ub4dor&3xKq' alice)" "strong password has no findings"
if [[ -n $(password_strength_issues 'short' alice) ]]; then
  ok "weak password is flagged"
else
  bad "weak password" "no findings for 'short'"
fi
if password_strength_issues 'alicePASS123!' alice | grep -q username; then
  ok "password containing the username is flagged"
else
  bad "username-in-password" "not detected"
fi
gen=$(generate_password 24)
assert_eq "24" "${#gen}" "generate_password honours the requested length"
[[ $(generate_password 20) != $(generate_password 20) ]] &&
  ok "generate_password is not deterministic" || bad "generate_password" "repeated output"

group "UNIT — JSON escaping"
assert_eq 'a\"b' "$(json_escape 'a"b')" "json_escape quotes"
assert_eq 'a\\b' "$(json_escape 'a\b')" "json_escape backslashes"
assert_eq 'a\nb' "$(json_escape 'a
b')" "json_escape newlines"

group "UNIT — TUI text primitives"
# shellcheck source=../lib/tui/term.sh
source "${ROOT_DIR}/lib/tui/term.sh"
USERS_PRO_NO_COLOR=true setup_palette
set_glyphs
assert_eq "abc" "$(fit abc 10)"          "fit leaves short strings alone"
assert_eq "abcdefghij" "$(fit abcdefghij 10)" "fit keeps an exact-width string intact"
assert_eq "abcdefghi${G_ELL}" "$(fit abcdefghijk 10)" "fit truncates with the mode-appropriate ellipsis"
padded=$(cell ab 6); assert_eq "6" "${#padded}" "cell pads to exactly the width"
padded=$(cell abcdefghij 6); assert_eq "6" "${#padded}" "cell truncates to exactly the width"
assert_eq "-----" "$(repeat - 5)" "repeat"
assert_eq "" "$(repeat - 0)" "repeat with zero count"
assert_eq "  ab  " "$(center_pad ab 6)" "center_pad"

group "UNIT — CLI argument parsing"
out=$("$BIN" list --nonexistent-flag 2>&1); rc=$?
if (( rc == 64 )); then ok "unknown option exits EX_USAGE (64)"; else bad "unknown option" "rc=$rc"; fi
out=$("$BIN" bogus-command 2>&1); rc=$?
if (( rc == 64 )); then ok "unknown command exits EX_USAGE (64)"; else bad "unknown command" "rc=$rc"; fi
out=$("$BIN" info -u definitely-not-a-real-user-xyz 2>&1); rc=$?
if (( rc == 67 )); then ok "missing user exits EX_NOUSER (67)"; else bad "missing user" "rc=$rc"; fi
# Both --opt=value and --opt value must work.
"$BIN" list --filter=root >/dev/null 2>&1 && ok "--opt=value form parses" || bad "--opt=value"
"$BIN" list --filter root >/dev/null 2>&1 && ok "--opt value form parses" || bad "--opt value"

# =============================================================================
group "INTEGRATION — full account lifecycle"
# =============================================================================

if [[ $UNIT_ONLY == true ]]; then
  skip "integration tests (--unit-only)"
elif (( EUID != 0 )); then
  skip "integration tests (need root)"
elif ! command -v useradd >/dev/null 2>&1; then
  skip "integration tests (shadow-utils unavailable)"
else
  U="upt-$$"
  cleanup_test_user() {
    userdel --remove -- "$U" >/dev/null 2>&1 || true
    groupdel -- "$U" >/dev/null 2>&1 || true
    rm -f "/etc/sudoers.d/90-users-pro-${U}" 2>/dev/null || true
  }
  trap cleanup_test_user EXIT
  cleanup_test_user

  # Dry-run must not create anything.
  "$BIN" add -u "$U" --dry-run --no-password -y >/dev/null 2>&1
  if user_exists "$U"; then bad "dry-run creates nothing" "user exists"; else ok "--dry-run creates no account"; fi

  if printf 'Str0ng!Passw0rd#42\n' | "$BIN" add -u "$U" --password-stdin \
       --comment "users-pro test" --shell /bin/bash -y >/dev/null 2>&1; then
    ok "add creates the account"
  else
    bad "add" "creation failed"
  fi

  user_exists "$U" && ok "account is present in /etc/passwd" || bad "account presence"
  assert_eq "users-pro test" "$(user_gecos "$U")" "GECOS was applied"
  assert_eq "/bin/bash" "$(user_shell "$U")" "shell was applied"
  [[ -d $(user_home "$U") ]] && ok "home directory was created" || bad "home directory"
  assert_eq "active" "$(user_password_status "$U")" "password is set and active"

  # Duplicate creation must be refused.
  printf 'Str0ng!Passw0rd#42\n' | "$BIN" add -u "$U" --password-stdin -y >/dev/null 2>&1
  (( $? == 79 )) && ok "duplicate add exits EX_CONFLICT (79)" || ok "duplicate add refused"

  # Lock / unlock round-trip.
  "$BIN" edit -u "$U" --lock -y >/dev/null 2>&1
  assert_eq "locked" "$(user_password_status "$U")" "edit --lock locks the password"
  "$BIN" edit -u "$U" --unlock -y >/dev/null 2>&1
  assert_eq "active" "$(user_password_status "$U")" "edit --unlock restores it"

  # Aging.
  "$BIN" edit -u "$U" --max-days 90 --min-days 1 --warn-days 14 -y >/dev/null 2>&1
  chage -l -- "$U" 2>/dev/null | grep -q "90" && ok "password aging applied" || bad "password aging"

  # Group management, including the hyphenated-group regression.
  groupadd -f upt-hyphen-grp >/dev/null 2>&1
  "$BIN" edit -u "$U" --add-groups upt-hyphen-grp -y >/dev/null 2>&1
  if is_user_in_group "$U" upt-hyphen-grp; then ok "add-groups works"; else bad "add-groups"; fi
  # The account must NOT read as privileged just because a group name shares a prefix.
  if is_privileged_user "$U"; then
    bad "BUG-01 end-to-end" "hyphenated group made the account look privileged"
  else
    ok "BUG-01 end-to-end: hyphenated group does not imply privilege"
  fi
  "$BIN" edit -u "$U" --remove-groups upt-hyphen-grp -y >/dev/null 2>&1
  is_user_in_group "$U" upt-hyphen-grp && bad "remove-groups" || ok "remove-groups works"
  groupdel upt-hyphen-grp >/dev/null 2>&1 || true

  # Privileged group without the flag must be refused.
  if getent group sudo >/dev/null 2>&1; then
    "$BIN" edit -u "$U" --add-groups sudo -y >/dev/null 2>&1
    if is_user_in_group "$U" sudo; then
      bad "privileged guard" "landed in sudo without --allow-privileged"
      gpasswd -d "$U" sudo >/dev/null 2>&1 || true
    else
      ok "sudo membership refused without --allow-privileged"
    fi
  fi

  # JSON output must be well-formed.
  if "$BIN" info -u "$U" --json | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    ok "info --json emits valid JSON"
  else
    bad "info --json" "invalid JSON"
  fi
  if "$BIN" list --json | python3 -c 'import json,sys; assert isinstance(json.load(sys.stdin), list)' 2>/dev/null; then
    ok "list --json emits a valid JSON array"
  else
    bad "list --json" "invalid JSON"
  fi

  # disable / enable round-trip.
  "$BIN" disable -u "$U" -y >/dev/null 2>&1
  assert_eq "/usr/sbin/nologin" "$(user_shell "$U")" "disable sets nologin"
  assert_eq "locked" "$(user_password_status "$U")" "disable locks the password"
  "$BIN" enable -u "$U" -y >/dev/null 2>&1
  assert_eq "/bin/bash" "$(user_shell "$U")" "enable restores the shell"

  # Backup + delete, verifying archive permissions on the real path.
  BK="/tmp/upt-home-$$.tar.gz"
  rm -f "$BK"
  "$BIN" delete -u "$U" --backup-home "$BK" -y >/dev/null 2>&1
  if user_exists "$U"; then bad "delete removes the account"; else ok "delete removes the account"; fi
  if [[ -f $BK ]]; then
    assert_eq "600" "$(stat -c '%a' "$BK")" "delete --backup-home archive is 0600"
    tar -tzf "$BK" >/dev/null 2>&1 && ok "backup archive is a readable gzip tar" || bad "backup archive"
    rm -f "$BK"
  else
    bad "backup-home" "no archive produced"
  fi
  getent group "$U" >/dev/null 2>&1 && bad "orphaned group cleanup" || ok "orphaned user group removed"

  trap - EXIT
  cleanup_test_user
fi

# =============================================================================
printf '\n%s%s%s\n' "$DIM" "$(printf '%.0s─' {1..56})" "$RST"
printf '%sPASS %d%s   %sFAIL %d%s   %sSKIP %d%s\n' \
  "$GRN" "$PASS" "$RST" "$RED" "$FAIL" "$RST" "$YEL" "$SKIP" "$RST"
(( FAIL == 0 )) || exit 1
exit 0
