#!/usr/bin/env bash
# shellcheck disable=SC2015
# SC2015 file-wide: ok() and bad() always return 0, so `cond && ok || bad`
# cannot double-fire. See tests/run-tests.sh.
# shellcheck disable=SC2329
# SC2329: reject() is a symmetric helper alongside expect(), kept for the
# negative assertions added as the interface grows.
# =============================================================================
# tests/tui-tests.sh — Interface regression tests.
#
# These drive the real binary through a pty and assert on the rendered frame,
# because every TUI bug found during development (SIGWINCH kill, XOFF swallow,
# geometry clobber, column jitter) was invisible to static analysis and to the
# unit suite. Rendering code that is never run is a hypothesis, not a feature.
#
# Usage: sudo tests/tui-tests.sh
# Requires python3 (present on any Ubuntu server).
# =============================================================================

set -uo pipefail


TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
DRIVE="${TEST_DIR}/tui-drive.py"
export TEST_DIR
PASS=0 FAIL=0 SKIP=0

RED=$'\033[31m' GRN=$'\033[32m' YEL=$'\033[33m' DIM=$'\033[2m' RST=$'\033[0m'
[[ -t 1 ]] || { RED="" GRN="" YEL="" DIM="" RST=""; }
ok()   { PASS=$((PASS+1)); printf '  %sPASS%s %s\n' "$GRN" "$RST" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  %sFAIL%s %s\n' "$RED" "$RST" "$1"; [[ -n ${2:-} ]] && printf '       %s%s%s\n' "$DIM" "$2" "$RST"; }
skip() { SKIP=$((SKIP+1)); printf '  %sSKIP%s %s\n' "$YEL" "$RST" "$1"; }
group(){ printf '\n%s%s%s\n' "$DIM" "$1" "$RST"; }

command -v python3 >/dev/null 2>&1 || { skip "TUI tests (python3 unavailable)"; exit 0; }
[[ -t 0 || -e /dev/ptmx ]] || { skip "TUI tests (no pty support)"; exit 0; }

# frame <keys-json> [cols] [rows]
frame() { timeout 120 python3 "$DRIVE" "$1" "${2:-100}" "${3:-26}" 2>/dev/null; }

# expect <name> <keys> <pattern>
expect() {
  local name=$1 keys=$2 pattern=$3 cols=${4:-100} rows=${5:-26} out
  out=$(frame "$keys" "$cols" "$rows")
  if grep -qF -- "$pattern" <<<"$out"; then
    ok "$name"
  else
    bad "$name" "frame did not contain: ${pattern}"
  fi
}

reject() {
  local name=$1 keys=$2 pattern=$3 out
  out=$(frame "$keys")
  if grep -qF -- "$pattern" <<<"$out"; then
    bad "$name" "frame unexpectedly contained: ${pattern}"
  else
    ok "$name"
  fi
}

group "TUI — startup and layout"

# REGRESSION: term_size() ended in `(( TERM_COLS < 40 )) && TERM_COLS=40`, which
# returns 1 whenever no clamping is needed. Called bare under `set -e`, the very
# first SIGWINCH (any terminal resize) killed the process.
out=$(frame '[]')
if [[ -z $out ]] || grep -q "exited with code" <<<"$out"; then
  bad "survives the initial SIGWINCH" "process died on resize"
else
  ok "survives the initial SIGWINCH (errexit landmine in term_size)"
fi

expect "renders the header bar"        '[]' "users-pro "
expect "renders the account pane"      '[]' "Accounts"
expect "renders the detail pane"       '[]' "IDENTITY"
expect "renders the key bar"           '[]' "a·add"
expect "lists root"                    '[]' "root"

group "TUI — navigation"
expect "help overlay opens on ?"       '["?"]' "NAVIGATE"
expect "help lists the save binding"   '["?"]' "typing the account name"
expect "detail pane scrolls on ]"      '["]"]' "last login"
expect "filter mode narrows the list"  '["/","r","o","o","t"]' "Accounts  /root"
expect "Tab reveals system accounts"   '["\t"]' "[+system]"

group "TUI — layout at awkward sizes"
expect "usable at 80x24"               '[]' "Accounts" 80 24
expect "usable at 200x50"              '[]' "IDENTITY" 200 50
out=$(frame '[]' 60 14)
if [[ -n $out ]] && ! grep -q "exited with code" <<<"$out"; then
  ok "survives a cramped 60x14 terminal"
else
  bad "cramped terminal" "died or rendered nothing"
fi

group "TUI — forms"
expect "create form opens on a"        '["a"]' "Create account"
expect "form shows the shell selector" '["a"]' "/bin/bash"
# REGRESSION: modal_geometry writes shared globals; a nested input_box used to
# resize the parent form behind it.
expect "form keeps its size after a nested editor" \
       '["a","\r","x","\r"]' "allow privileged"
# REGRESSION: selected and unselected rows padded values differently, so the
# value column shifted by one character as the cursor moved.
out=$(frame '["a","\t"]')
c1=$(grep -o 'full name *[—▸]' <<<"$out" | head -1 | wc -c)
c2=$(grep -o 'expire date *[—▸]' <<<"$out" | head -1 | wc -c)
if [[ -n $c1 && $c1 == "$c2" ]]; then
  ok "form value column does not jitter with the cursor"
else
  bad "form column alignment" "widths ${c1} vs ${c2}"
fi

group "TUI — destructive gates"
if (( EUID != 0 )); then
  skip "lifecycle tests (need root)"
elif ! command -v useradd >/dev/null 2>&1; then
  skip "lifecycle tests (shadow-utils unavailable)"
else
  U=tuitest-smoke
  userdel --remove "$U" >/dev/null 2>&1
  groupdel "$U" >/dev/null 2>&1

  # REGRESSION: Ctrl-S is 0x13 (XOFF). Without `stty -ixon` the tty driver ate
  # it as flow control, and 0x13 was also missing from the key decoder — so the
  # documented save binding did nothing at all.
  keys='["a","\r"'
  for ((i=0;i<${#U};i++)); do keys+=",\"${U:i:1}\""; done
  keys+=',"\r","\t","\t","\t","\t","\t"," ","\u0013"]'
  frame "$keys" >/dev/null
  if getent passwd "$U" >/dev/null 2>&1; then
    ok "Ctrl-S submits the form and the account is created"
  else
    bad "Ctrl-S submit" "no account created"
  fi

  if [[ -d /home/$U ]]; then
    mode=$(stat -c '%a' "/home/$U")
    [[ $mode == 750 || $mode == 700 ]] && ok "home directory is not world-readable (${mode})" \
      || bad "home permissions" "mode ${mode}"
  fi

  # The typed-confirmation gate must refuse a mismatched name.
  frame '["\u001b[B","\u001b[B","\u001b[B","d","\u0013","w","r","o","n","g","\r"]' >/dev/null
  if getent passwd "$U" >/dev/null 2>&1; then
    ok "delete refused when the typed name does not match"
  else
    bad "delete gate" "account was removed on a wrong confirmation"
  fi

  # And accept the correct one.
  keys='["\u001b[B","\u001b[B","\u001b[B","d","\u0013"'
  for ((i=0;i<${#U};i++)); do keys+=",\"${U:i:1}\""; done
  keys+=',"\r"]'
  frame "$keys" >/dev/null
  if getent passwd "$U" >/dev/null 2>&1; then
    bad "delete completes" "account survived a correct confirmation"
    userdel --remove "$U" >/dev/null 2>&1
  else
    ok "delete completes when the typed name matches"
  fi
  getent group "$U" >/dev/null 2>&1 && { bad "orphan group"; groupdel "$U" >/dev/null 2>&1; } \
    || ok "orphan group cleaned up"
fi

group "TUI — safety"

# Dry-run must be visible at a glance so a rehearsal is never mistaken for the
# real thing, or vice versa.
out=$(timeout 120 python3 "$DRIVE" '[]' 100 24 -- --dry-run 2>/dev/null)
if grep -qF "DRY-RUN" <<<"$out"; then
  ok "dry-run badge is rendered in the header"
else
  bad "dry-run badge" "header showed no DRY-RUN marker"
fi

out=$(timeout 120 python3 "$DRIVE" '[]' 100 24 2>/dev/null)
if grep -qF "DRY-RUN" <<<"$out"; then
  bad "no false dry-run badge" "badge shown while dry-run is off"
else
  ok "no dry-run badge when the mode is off"
fi

# --no-color must produce a frame with no ANSI SGR sequences at all, for
# terminals and log captures that cannot handle them.
raw=$(timeout 120 python3 - <<'PY' 2>/dev/null
import sys, os, re
sys.path.insert(0, os.environ["TEST_DIR"])
from importlib.machinery import SourceFileLoader
d = SourceFileLoader("d", os.path.join(os.environ["TEST_DIR"], "tui-drive.py")).load_module()
text = d.drive([], 100, 24, argv=["--no-color"])
print("SGR_COUNT", len(re.findall(r"\x1b\[[0-9;]*m", text)))
PY
)
if grep -q "SGR_COUNT 0" <<<"$raw"; then
  ok "--no-color emits no colour escapes"
else
  bad "--no-color" "${raw:-no output}"
fi

printf '\n%s%s%s\n' "$DIM" "$(printf '%.0s─' {1..56})" "$RST"
printf '%sPASS %d%s   %sFAIL %d%s   %sSKIP %d%s\n' \
  "$GRN" "$PASS" "$RST" "$RED" "$FAIL" "$RST" "$YEL" "$SKIP" "$RST"
(( FAIL == 0 )) || exit 1
exit 0
