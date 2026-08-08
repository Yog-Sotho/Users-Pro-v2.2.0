#!/usr/bin/env bash
# =============================================================================
# lib/tui/term.sh — Terminal control, palette, and frame buffering.
# Everything renders into FRAME and is flushed in a single write, so the screen
# never tears and never flickers.
# =============================================================================

# shellcheck disable=SC2034
# SC2034 is suppressed file-wide: this is a sourced library. Constants, exit
# codes and palette variables declared here are consumed by sibling files that
# ShellCheck analyses as separate units, so it cannot see the reference.

[[ -n ${_USERS_PRO_TERM_LOADED:-} ]] && return 0
_USERS_PRO_TERM_LOADED=1

ESC=$'\033'
readonly ESC

TERM_ROWS=24
TERM_COLS=80
SAVED_STTY=""
ALT_SCREEN_ACTIVE=false

# =============================================================================
# Palette
# =============================================================================
# Degrades cleanly: truecolor -> 256 -> 16 -> plain. Honours NO_COLOR.

setup_palette() {
  local depth=0
  if [[ -n ${NO_COLOR:-} || ${USERS_PRO_NO_COLOR:-false} == true || $TERM == dumb ]]; then
    depth=0
  elif [[ ${COLORTERM:-} == truecolor || ${COLORTERM:-} == 24bit ]]; then
    depth=24
  elif [[ $TERM == *256color* ]]; then
    depth=8
  elif [[ -t 1 ]]; then
    depth=4
  fi

  if (( depth == 0 )); then
    C_RESET="" C_BOLD="" C_DIM="" C_ITALIC="" C_REV=""
    C_FG="" C_MUTED="" C_ACCENT="" C_OK="" C_WARN="" C_ERR="" C_INFO=""
    C_BAR="" C_SEL="" C_BORDER="" C_TITLE="" C_KEY=""
    GLYPH_MODE=ascii
    return 0
  fi

  C_RESET="${ESC}[0m"
  C_BOLD="${ESC}[1m"
  C_DIM="${ESC}[2m"
  C_ITALIC="${ESC}[3m"
  C_REV="${ESC}[7m"

  if (( depth == 24 )); then
    C_FG="${ESC}[38;2;226;232;240m"
    C_MUTED="${ESC}[38;2;120;132;150m"
    C_ACCENT="${ESC}[38;2;125;211;252m"
    C_OK="${ESC}[38;2;134;239;172m"
    C_WARN="${ESC}[38;2;253;224;71m"
    C_ERR="${ESC}[38;2;252;129;129m"
    C_INFO="${ESC}[38;2;196;181;253m"
    C_BAR="${ESC}[48;2;30;41;59m${ESC}[38;2;226;232;240m"
    C_SEL="${ESC}[48;2;51;65;85m${ESC}[38;2;248;250;252m${ESC}[1m"
    C_BORDER="${ESC}[38;2;71;85;105m"
    C_TITLE="${ESC}[38;2;125;211;252m${ESC}[1m"
    C_KEY="${ESC}[38;2;251;191;36m${ESC}[1m"
  elif (( depth == 8 )); then
    C_FG="${ESC}[38;5;252m"
    C_MUTED="${ESC}[38;5;245m"
    C_ACCENT="${ESC}[38;5;117m"
    C_OK="${ESC}[38;5;114m"
    C_WARN="${ESC}[38;5;221m"
    C_ERR="${ESC}[38;5;210m"
    C_INFO="${ESC}[38;5;183m"
    C_BAR="${ESC}[48;5;236m${ESC}[38;5;252m"
    C_SEL="${ESC}[48;5;238m${ESC}[38;5;255m${ESC}[1m"
    C_BORDER="${ESC}[38;5;240m"
    C_TITLE="${ESC}[38;5;117m${ESC}[1m"
    C_KEY="${ESC}[38;5;214m${ESC}[1m"
  else
    C_FG="${ESC}[37m"
    C_MUTED="${ESC}[90m"
    C_ACCENT="${ESC}[36m"
    C_OK="${ESC}[32m"
    C_WARN="${ESC}[33m"
    C_ERR="${ESC}[31m"
    C_INFO="${ESC}[35m"
    C_BAR="${ESC}[44m${ESC}[37m"
    C_SEL="${ESC}[7m"
    C_BORDER="${ESC}[90m"
    C_TITLE="${ESC}[36m${ESC}[1m"
    C_KEY="${ESC}[33m${ESC}[1m"
  fi

  # Box glyphs. UTF-8 locales get proper line drawing; everything else ASCII.
  if [[ ${LANG:-}${LC_ALL:-} == *[Uu][Tt][Ff]* ]]; then
    GLYPH_MODE=unicode
  else
    GLYPH_MODE=ascii
  fi
}

set_glyphs() {
  if [[ ${GLYPH_MODE:-ascii} == unicode ]]; then
    G_H='─' G_V='│' G_TL='╭' G_TR='╮' G_BL='╰' G_BR='╯'
    G_LT='├' G_RT='┤' G_TT='┬' G_BT='┴' G_X='┼'
    G_DOT='•' G_ARROW='▸' G_CHECK='✓' G_CROSS='✗' G_BLOCK='█' G_ELL='…'
  else
    G_H='-' G_V='|' G_TL='+' G_TR='+' G_BL='+' G_BR='+'
    G_LT='+' G_RT='+' G_TT='+' G_BT='+' G_X='+'
    G_DOT='*' G_ARROW='>' G_CHECK='y' G_CROSS='x' G_BLOCK='#' G_ELL='~'
  fi
}

# =============================================================================
# Screen lifecycle
# =============================================================================

term_size() {
  local size
  if size=$(stty size 2>/dev/null) && [[ $size =~ ^[0-9]+\ [0-9]+$ ]]; then
    TERM_ROWS=${size%% *}
    TERM_COLS=${size##* }
  else
    TERM_ROWS=${LINES:-24}
    TERM_COLS=${COLUMNS:-80}
  fi
  (( TERM_ROWS < 10 )) && TERM_ROWS=10
  (( TERM_COLS < 40 )) && TERM_COLS=40
  # Explicit success: this function's last statement is a `(( )) && assign`
  # guard, which evaluates false whenever no clamping is needed and would make
  # the function return 1. Called bare under `set -e`, that killed the TUI on
  # the first SIGWINCH.
  return 0
}

term_enter() {
  [[ -t 0 && -t 1 ]] || die "-$EX_USAGE" "The TUI requires an interactive terminal."
  SAVED_STTY=$(stty -g 2>/dev/null || true)
  # -ixon/-ixoff are essential: without them the tty driver swallows Ctrl-S
  # (0x13 = XOFF) as flow control and freezes the session instead of
  # delivering the key. Ctrl-Q (0x11) has the same problem.
  stty -echo -icanon -ixon -ixoff min 1 time 0 2>/dev/null || true
  printf '%s[?1049h%s[?25l' "$ESC" "$ESC"
  ALT_SCREEN_ACTIVE=true
  term_size
  set_glyphs
}

term_leave() {
  [[ $ALT_SCREEN_ACTIVE == true ]] || return 0
  printf '%s[?25h%s[?1049l%s' "$ESC" "$ESC" "${C_RESET:-}"
  [[ -n $SAVED_STTY ]] && stty "$SAVED_STTY" 2>/dev/null || stty sane 2>/dev/null || true
  ALT_SCREEN_ACTIVE=false
}

term_show_cursor() { printf '%s[?25h' "$ESC"; }
term_hide_cursor() { printf '%s[?25l' "$ESC"; }

# =============================================================================
# Frame buffer
# =============================================================================

FRAME=""

frame_begin() { FRAME="${ESC}[H${ESC}[2J"; }
frame_at() { FRAME+="${ESC}[${1};${2}H"; }
frame_add() { FRAME+="$1"; }
frame_line() { FRAME+="${ESC}[${1};${2}H${3}"; }
frame_flush() { printf '%s' "$FRAME"; }

# =============================================================================
# Text helpers
# =============================================================================

# Strip ANSI so width maths stays honest.
strip_ansi() {
  local s=$1
  # shellcheck disable=SC2001  # the pattern needs a regex, not a glob
  printf '%s' "$(sed -E $'s/\033\\[[0-9;?]*[a-zA-Z]//g' <<<"$s")"
}

# Truncate to width, appending an ellipsis when it does not fit.
#
# The ellipsis tracks GLYPH_MODE instead of being hardcoded. Under a non-UTF-8
# locale the multi-byte character is three bytes that bash counts as three
# characters and the terminal renders as mojibake, so every column to its right
# drifts and the layout shears. G_ELL always occupies exactly one cell.
fit() {
  local s=$1 width=$2
  (( width <= 0 )) && { printf ''; return 0; }
  if (( ${#s} <= width )); then
    printf '%s' "$s"
  elif (( width == 1 )); then
    printf '%s' "${G_ELL:-~}"
  else
    printf '%s%s' "${s:0:width-1}" "${G_ELL:-~}"
  fi
}

# Truncate, then pad to exactly `width` display columns.
cell() {
  local width=$2 s pad
  s=$(fit "$1" "$width")
  pad=$(( width - ${#s} ))
  (( pad < 0 )) && pad=0
  printf '%s%*s' "$s" "$pad" ''
}

repeat() {
  local ch=$1 n=$2 out=""
  (( n <= 0 )) && { printf ''; return 0; }
  printf -v out '%*s' "$n" ''
  printf '%s' "${out// /$ch}"
}

center_pad() {
  local text=$1 width=$2 len=${#1} left
  (( len >= width )) && { fit "$text" "$width"; return 0; }
  left=$(( (width - len) / 2 ))
  printf '%*s%s%*s' "$left" '' "$text" "$(( width - len - left ))" ''
}

# =============================================================================
# Box drawing
# =============================================================================

# draw_box <top> <left> <height> <width> <title> <color>
draw_box() {
  local top=$1 left=$2 height=$3 width=$4 title=${5:-} color=${6:-$C_BORDER}
  local inner=$(( width - 2 )) r
  (( inner < 1 )) && return 0

  local top_line
  if [[ -n $title ]]; then
    local label=" ${title} "
    label=$(fit "$label" "$inner")
    top_line="${G_TL}${G_H}${C_TITLE}${label}${C_RESET}${color}$(repeat "$G_H" $(( inner - 1 - ${#label} )))${G_TR}"
  else
    top_line="${G_TL}$(repeat "$G_H" "$inner")${G_TR}"
  fi
  frame_line "$top" "$left" "${color}${top_line}${C_RESET}"

  for (( r = 1; r < height - 1; r++ )); do
    frame_line $(( top + r )) "$left" "${color}${G_V}${C_RESET}"
    frame_line $(( top + r )) $(( left + width - 1 )) "${color}${G_V}${C_RESET}"
  done

  frame_line $(( top + height - 1 )) "$left" \
    "${color}${G_BL}$(repeat "$G_H" "$inner")${G_BR}${C_RESET}"
}

# Fill a rectangle with spaces — used to clear behind modals.
clear_rect() {
  local top=$1 left=$2 height=$3 width=$4 r blank
  printf -v blank '%*s' "$width" ''
  for (( r = 0; r < height; r++ )); do
    frame_line $(( top + r )) "$left" "$blank"
  done
}
