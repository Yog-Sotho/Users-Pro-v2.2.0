#!/usr/bin/env bash
# =============================================================================
# lib/tui/input.sh — Blocking key reader that decodes escape sequences into
# stable names: UP DOWN LEFT RIGHT HOME END PGUP PGDN DEL ENTER TAB BTAB ESC
# BACKSPACE SPACE, C-<letter>, or the literal character.
# =============================================================================

# shellcheck disable=SC2034
# SC2034: KEY and RESIZED are the documented outputs of this module, read by
# lib/tui/app.sh and lib/tui/widgets.sh.

[[ -n ${_USERS_PRO_INPUT_LOADED:-} ]] && return 0
_USERS_PRO_INPUT_LOADED=1

KEY=""
RESIZED=false

on_sigwinch() { RESIZED=true; }

# read_key [timeout_seconds]
# Returns 1 when the read timed out with nothing pending (lets the caller run
# its idle work, e.g. redrawing after SIGWINCH).
read_key() {
  local timeout=${1:-} char="" rest="" rc=0

  KEY=""
  if [[ -n $timeout ]]; then
    IFS= read -rsN1 -t "$timeout" char || rc=$?
  else
    IFS= read -rsN1 char || rc=$?
  fi
  (( rc != 0 )) && return 1

  case $char in
    $'\033')
      # Escape: peek for the remainder of a CSI/SS3 sequence. A bare ESC has
      # nothing following, so the tiny timeout distinguishes the two.
      local next=""
      if ! IFS= read -rsN1 -t 0.02 next; then
        KEY=ESC
        return 0
      fi
      case $next in
        '[')
          local seq="" c=""
          while IFS= read -rsN1 -t 0.05 c; do
            seq+=$c
            [[ $c == [A-Za-z~] ]] && break
          done
          case $seq in
            A) KEY=UP ;;      B) KEY=DOWN ;;
            C) KEY=RIGHT ;;   D) KEY=LEFT ;;
            H|'1~'|'7~') KEY=HOME ;;
            F|'4~'|'8~') KEY=END ;;
            '5~') KEY=PGUP ;; '6~') KEY=PGDN ;;
            '3~') KEY=DEL ;;
            'Z')  KEY=BTAB ;;
            *)    KEY="CSI:${seq}" ;;
          esac
          ;;
        'O')
          local c2=""
          IFS= read -rsN1 -t 0.05 c2 || true
          case $c2 in
            A) KEY=UP ;;  B) KEY=DOWN ;;  C) KEY=RIGHT ;;  D) KEY=LEFT ;;
            H) KEY=HOME ;; F) KEY=END ;;
            *) KEY="SS3:${c2}" ;;
          esac
          ;;
        *) KEY="M-${next}" ;;
      esac
      ;;
    $'\n'|$'\r') KEY=ENTER ;;
    $'\t')       KEY=TAB ;;
    $'\177'|$'\b') KEY=BACKSPACE ;;
    ' ')         KEY=SPACE ;;
    $'\001') KEY=C-a ;; $'\002') KEY=C-b ;; $'\003') KEY=C-c ;;
    $'\004') KEY=C-d ;; $'\005') KEY=C-e ;; $'\006') KEY=C-f ;;
    $'\007') KEY=C-g ;; $'\013') KEY=C-k ;; $'\014') KEY=C-l ;;
    $'\016') KEY=C-n ;; $'\017') KEY=C-o ;; $'\020') KEY=C-p ;;
    $'\021') KEY=C-q ;; $'\022') KEY=C-r ;; $'\023') KEY=C-s ;;
    $'\024') KEY=C-t ;; $'\025') KEY=C-u ;; $'\026') KEY=C-v ;;
    $'\027') KEY=C-w ;; $'\030') KEY=C-x ;; $'\031') KEY=C-y ;;
    *) KEY=$char ;;
  esac
  unset rest
  return 0
}

# Drain anything still buffered — used after slow operations so a held-down
# arrow key does not queue up dozens of stale events.
flush_input() {
  local junk
  while IFS= read -rsN1 -t 0.001 junk; do :; done
  unset junk
  return 0
}
