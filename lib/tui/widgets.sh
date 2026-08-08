#!/usr/bin/env bash
# =============================================================================
# lib/tui/widgets.sh — Overlay widgets: message boxes, confirmations, single
# line editors, pickers, and multi-field forms.
#
# Every widget repaints the underlying screen through $TUI_BASE_RENDERER before
# drawing itself, so overlays compose without the caller tracking dirty regions.
# =============================================================================

# shellcheck disable=SC2034
# SC2034: WIDGET_CANCELLED, SELECT_RESULT, SELECT_INDEX, INPUT_RESULT and
# FORM_SUBMITTED are this module's documented return channel, read by
# lib/tui/app.sh.

[[ -n ${_USERS_PRO_WIDGETS_LOADED:-} ]] && return 0
_USERS_PRO_WIDGETS_LOADED=1

TUI_BASE_RENDERER="render_noop"
render_noop() { frame_begin; }

# Results
INPUT_RESULT=""
SELECT_RESULT=""
SELECT_INDEX=-1
WIDGET_CANCELLED=false

# --- Geometry helper ---------------------------------------------------------

# modal_geometry <desired_height> <desired_width> -> sets MODAL_TOP/LEFT/H/W
MODAL_TOP=0 MODAL_LEFT=0 MODAL_H=0 MODAL_W=0
modal_geometry() {
  local h=$1 w=$2
  (( w > TERM_COLS - 4 )) && w=$(( TERM_COLS - 4 ))
  (( h > TERM_ROWS - 4 )) && h=$(( TERM_ROWS - 4 ))
  (( w < 24 )) && w=24
  (( h < 5 )) && h=5
  MODAL_H=$h
  MODAL_W=$w
  MODAL_TOP=$(( (TERM_ROWS - h) / 2 ))
  MODAL_LEFT=$(( (TERM_COLS - w) / 2 ))
  (( MODAL_TOP < 1 )) && MODAL_TOP=1
  (( MODAL_LEFT < 1 )) && MODAL_LEFT=1
  return 0   # see term_size(): a trailing `&&` guard would return 1 when false
}

# Wrap text to a width, emitting one line per output row.
wrap_text() {
  local text=$1 width=$2 line="" word
  for word in $text; do
    if (( ${#line} + ${#word} + 1 > width )); then
      [[ -n $line ]] && printf '%s\n' "$line"
      line=$word
    else
      [[ -n $line ]] && line+=" $word" || line=$word
    fi
  done
  [[ -n $line ]] && printf '%s\n' "$line"
  return 0
}

# =============================================================================
# Message box
# =============================================================================

# msg_box <title> <color> <body...>
msg_box() {
  local title=$1 color=$2
  shift 2
  local -a body=("$@")
  local -a lines=()
  local raw maxw=${#title}

  for raw in "${body[@]}"; do
    if (( ${#raw} > TERM_COLS - 12 )); then
      mapfile -t -O "${#lines[@]}" lines < <(wrap_text "$raw" $(( TERM_COLS - 12 )))
    else
      lines+=("$raw")
    fi
  done
  for raw in "${lines[@]}"; do
    (( ${#raw} > maxw )) && maxw=${#raw}
  done

  modal_geometry $(( ${#lines[@]} + 4 )) $(( maxw + 6 ))

  "$TUI_BASE_RENDERER"
  clear_rect "$MODAL_TOP" "$MODAL_LEFT" "$MODAL_H" "$MODAL_W"
  draw_box "$MODAL_TOP" "$MODAL_LEFT" "$MODAL_H" "$MODAL_W" "$title" "$color"

  local i row
  for (( i = 0; i < ${#lines[@]} && i < MODAL_H - 3; i++ )); do
    row=$(( MODAL_TOP + 1 + i ))
    frame_line "$row" $(( MODAL_LEFT + 2 )) \
      "${C_FG}$(fit "${lines[i]}" $(( MODAL_W - 4 )))${C_RESET}"
  done
  local shown=$i hidden=$(( ${#lines[@]} - i ))
  local footer="press any key"
  (( hidden > 0 )) && footer="press any key  ${G_DOT}  ${hidden} more line(s) not shown"
  frame_line $(( MODAL_TOP + MODAL_H - 2 )) $(( MODAL_LEFT + 2 )) \
    "${C_MUTED}$(fit "$footer" $(( MODAL_W - 4 )))${C_RESET}"
  unset shown
  frame_flush
  read_key || true
}

# =============================================================================
# Confirmation
# =============================================================================

# confirm_box <title> <question> [danger]
# Returns 0 for yes. When `danger` is set the default is No and the box is red.
confirm_box() {
  local title=$1 question=$2 danger=${3:-no}
  local choice=1 color=$C_ACCENT
  [[ $danger == yes ]] && { color=$C_ERR; choice=1; }

  local -a lines=()
  mapfile -t lines < <(wrap_text "$question" $(( TERM_COLS - 14 )))
  local maxw=${#title} l
  for l in "${lines[@]}"; do (( ${#l} > maxw )) && maxw=${#l}; done
  (( maxw < 34 )) && maxw=34

  while true; do
    # Recomputed every pass: MODAL_* are shared globals that any nested widget
    # will overwrite, and this also tracks terminal resizes.
    modal_geometry $(( ${#lines[@]} + 5 )) $(( maxw + 6 ))
    "$TUI_BASE_RENDERER"
    clear_rect "$MODAL_TOP" "$MODAL_LEFT" "$MODAL_H" "$MODAL_W"
    draw_box "$MODAL_TOP" "$MODAL_LEFT" "$MODAL_H" "$MODAL_W" "$title" "$color"

    local i
    for (( i = 0; i < ${#lines[@]}; i++ )); do
      frame_line $(( MODAL_TOP + 1 + i )) $(( MODAL_LEFT + 2 )) \
        "${C_FG}$(fit "${lines[i]}" $(( MODAL_W - 4 )))${C_RESET}"
    done

    local yes_label="  Yes  " no_label="   No   "
    local yes_style=$C_MUTED no_style=$C_MUTED
    (( choice == 0 )) && yes_style="${C_SEL}"
    (( choice == 1 )) && no_style="${C_SEL}"
    frame_line $(( MODAL_TOP + MODAL_H - 2 )) $(( MODAL_LEFT + 3 )) \
      "${yes_style}${yes_label}${C_RESET}   ${no_style}${no_label}${C_RESET}"
    frame_line $(( MODAL_TOP + MODAL_H - 2 )) $(( MODAL_LEFT + MODAL_W - 22 )) \
      "${C_MUTED}←/→ • enter • esc${C_RESET}"
    frame_flush

    read_key || continue
    case $KEY in
      LEFT|h|UP)   choice=0 ;;
      RIGHT|l|DOWN) choice=1 ;;
      TAB)         choice=$(( (choice + 1) % 2 )) ;;
      y|Y)         return 0 ;;
      n|N|ESC|q)   return 1 ;;
      ENTER)       (( choice == 0 )) && return 0 || return 1 ;;
    esac
  done
}

# danger_box <title> <question> <required_text>
# Destructive actions require typing the exact subject name. Muscle memory
# cannot fire this by accident.
danger_box() {
  local title=$1 question=$2 required_text=$3 typed=""
  local -a lines=()
  mapfile -t lines < <(wrap_text "$question" $(( TERM_COLS - 14 )))
  local maxw=48 l
  for l in "${lines[@]}"; do (( ${#l} > maxw )) && maxw=${#l}; done

  while true; do
    modal_geometry $(( ${#lines[@]} + 7 )) $(( maxw + 6 ))
    "$TUI_BASE_RENDERER"
    clear_rect "$MODAL_TOP" "$MODAL_LEFT" "$MODAL_H" "$MODAL_W"
    draw_box "$MODAL_TOP" "$MODAL_LEFT" "$MODAL_H" "$MODAL_W" "$title" "$C_ERR"

    local i
    for (( i = 0; i < ${#lines[@]}; i++ )); do
      frame_line $(( MODAL_TOP + 1 + i )) $(( MODAL_LEFT + 2 )) \
        "${C_FG}$(fit "${lines[i]}" $(( MODAL_W - 4 )))${C_RESET}"
    done

    local prompt_row=$(( MODAL_TOP + ${#lines[@]} + 2 ))
    frame_line "$prompt_row" $(( MODAL_LEFT + 2 )) \
      "${C_WARN}Type ${C_BOLD}${required_text}${C_RESET}${C_WARN} to confirm:${C_RESET}"
    local ok_mark=""
    [[ $typed == "$required_text" ]] && ok_mark=" ${C_OK}${G_CHECK}${C_RESET}"
    frame_line $(( prompt_row + 1 )) $(( MODAL_LEFT + 2 )) \
      "${C_BAR} $(cell "$typed" $(( MODAL_W - 10 ))) ${C_RESET}${ok_mark}"
    frame_line $(( MODAL_TOP + MODAL_H - 2 )) $(( MODAL_LEFT + 2 )) \
      "${C_MUTED}enter to proceed • esc to cancel${C_RESET}"
    frame_flush

    read_key || continue
    case $KEY in
      ESC) return 1 ;;
      ENTER) [[ $typed == "$required_text" ]] && return 0 ;;
      BACKSPACE) typed=${typed%?} ;;
      C-u) typed="" ;;
      SPACE) typed+=" " ;;
      ?) [[ $KEY == [[:print:]] ]] && typed+=$KEY ;;
    esac
  done
}

# =============================================================================
# Single-line editor
# =============================================================================

# input_box <title> <prompt> <default> [masked]
input_box() {
  local title=$1 prompt=$2 value=${3:-} masked=${4:-no}
  WIDGET_CANCELLED=false

  local width=$(( ${#prompt} + 12 ))
  (( width < 52 )) && width=52

  while true; do
    modal_geometry 7 "$width"
    "$TUI_BASE_RENDERER"
    clear_rect "$MODAL_TOP" "$MODAL_LEFT" "$MODAL_H" "$MODAL_W"
    draw_box "$MODAL_TOP" "$MODAL_LEFT" "$MODAL_H" "$MODAL_W" "$title" "$C_ACCENT"

    frame_line $(( MODAL_TOP + 1 )) $(( MODAL_LEFT + 2 )) \
      "${C_FG}$(fit "$prompt" $(( MODAL_W - 4 )))${C_RESET}"

    local shown=$value
    [[ $masked == yes ]] && shown=$(repeat '*' "${#value}")
    local field_w=$(( MODAL_W - 6 ))
    local view=$shown
    (( ${#view} > field_w )) && view=${shown: -field_w}
    frame_line $(( MODAL_TOP + 3 )) $(( MODAL_LEFT + 2 )) \
      "${C_BAR} $(cell "$view" $(( field_w - 1 )))${C_RESET}"
    frame_line $(( MODAL_TOP + MODAL_H - 2 )) $(( MODAL_LEFT + 2 )) \
      "${C_MUTED}enter to accept • esc to cancel${C_RESET}"
    frame_flush

    read_key || continue
    case $KEY in
      ENTER) INPUT_RESULT=$value; return 0 ;;
      ESC)   WIDGET_CANCELLED=true; INPUT_RESULT=""; return 1 ;;
      BACKSPACE) value=${value%?} ;;
      C-u)   value="" ;;
      C-w)   value=${value% *} ;;
      SPACE) value+=" " ;;
      TAB|UP|DOWN|LEFT|RIGHT|HOME|END|PGUP|PGDN|DEL|BTAB) : ;;
      ?)     [[ $KEY == [[:print:]] ]] && value+=$KEY ;;
    esac
  done
}

# =============================================================================
# Picker
# =============================================================================

# select_box <title> <item>...
select_box() {
  local title=$1
  shift
  local -a items=("$@")
  local count=${#items[@]}
  (( count > 0 )) || { SELECT_RESULT=""; SELECT_INDEX=-1; return 1; }

  local idx=0 offset=0 filter=""
  local -a view_idx=()
  WIDGET_CANCELLED=false

  local maxw=${#title} it
  for it in "${items[@]}"; do (( ${#it} > maxw )) && maxw=${#it}; done
  (( maxw < 34 )) && maxw=34

  local rows visible
  while true; do
    rows=$(( count + 6 ))
    (( rows > TERM_ROWS - 4 )) && rows=$(( TERM_ROWS - 4 ))
    modal_geometry "$rows" $(( maxw + 8 ))
    visible=$(( MODAL_H - 5 ))
    (( visible < 1 )) && visible=1
    view_idx=()
    local i
    for (( i = 0; i < count; i++ )); do
      if [[ -z $filter || ${items[i],,} == *"${filter,,}"* ]]; then
        view_idx+=("$i")
      fi
    done
    local vcount=${#view_idx[@]}
    (( idx >= vcount )) && idx=$(( vcount - 1 ))
    (( idx < 0 )) && idx=0
    (( idx < offset )) && offset=$idx
    (( idx >= offset + visible )) && offset=$(( idx - visible + 1 ))
    (( offset < 0 )) && offset=0

    "$TUI_BASE_RENDERER"
    clear_rect "$MODAL_TOP" "$MODAL_LEFT" "$MODAL_H" "$MODAL_W"
    draw_box "$MODAL_TOP" "$MODAL_LEFT" "$MODAL_H" "$MODAL_W" "$title" "$C_ACCENT"

    frame_line $(( MODAL_TOP + 1 )) $(( MODAL_LEFT + 2 )) \
      "${C_MUTED}filter:${C_RESET} ${C_FG}$(cell "${filter:-<type to filter>}" $(( MODAL_W - 13 )))${C_RESET}"

    local r label
    for (( r = 0; r < visible; r++ )); do
      local vi=$(( offset + r ))
      local row=$(( MODAL_TOP + 3 + r ))
      if (( vi < vcount )); then
        label=${items[${view_idx[vi]}]}
        if (( vi == idx )); then
          frame_line "$row" $(( MODAL_LEFT + 2 )) \
            "${C_SEL} ${G_ARROW} $(cell "$label" $(( MODAL_W - 8 )))${C_RESET}"
        else
          frame_line "$row" $(( MODAL_LEFT + 2 )) \
            "${C_FG}   $(cell "$label" $(( MODAL_W - 8 )))${C_RESET}"
        fi
      else
        frame_line "$row" $(( MODAL_LEFT + 2 )) "$(repeat ' ' $(( MODAL_W - 4 )))"
      fi
    done

    frame_line $(( MODAL_TOP + MODAL_H - 2 )) $(( MODAL_LEFT + 2 )) \
      "${C_MUTED}$(( vcount ))/${count} • enter • esc${C_RESET}"
    frame_flush

    read_key || continue
    case $KEY in
      UP)    (( idx > 0 )) && idx=$(( idx - 1 )) ;;
      DOWN)  (( idx < vcount - 1 )) && idx=$(( idx + 1 )) ;;
      PGUP)  idx=$(( idx - visible )); (( idx < 0 )) && idx=0 ;;
      PGDN)  idx=$(( idx + visible )); (( idx > vcount - 1 )) && idx=$(( vcount - 1 )) ;;
      HOME)  idx=0 ;;
      END)   idx=$(( vcount - 1 )) ;;
      ENTER)
        (( vcount > 0 )) || continue
        SELECT_INDEX=${view_idx[idx]}
        SELECT_RESULT=${items[$SELECT_INDEX]}
        return 0
        ;;
      ESC)   WIDGET_CANCELLED=true; SELECT_RESULT=""; SELECT_INDEX=-1; return 1 ;;
      BACKSPACE) filter=${filter%?}; idx=0; offset=0 ;;
      C-u)   filter=""; idx=0; offset=0 ;;
      ?)     [[ $KEY == [[:print:]] ]] && { filter+=$KEY; idx=0; offset=0; } ;;
    esac
  done
}

# =============================================================================
# Multi-field form
# =============================================================================
# Callers populate the parallel arrays, then call form_run.
#   FORM_LABELS  visible label
#   FORM_VALUES  current value (also the default)
#   FORM_TYPES   text | password | toggle | select | note
#   FORM_CHOICES pipe-separated options for `select` and `toggle`
#   FORM_HINTS   one-line help shown under the form

declare -a FORM_LABELS=() FORM_VALUES=() FORM_TYPES=() FORM_CHOICES=() FORM_HINTS=()
FORM_SUBMITTED=false

form_reset() {
  FORM_LABELS=() FORM_VALUES=() FORM_TYPES=() FORM_CHOICES=() FORM_HINTS=()
  FORM_SUBMITTED=false
}

form_add() {
  FORM_LABELS+=("$1")
  FORM_VALUES+=("${2:-}")
  FORM_TYPES+=("${3:-text}")
  FORM_CHOICES+=("${4:-}")
  FORM_HINTS+=("${5:-}")
}

form_value_of() {
  local label=$1 i
  for (( i = 0; i < ${#FORM_LABELS[@]}; i++ )); do
    [[ ${FORM_LABELS[i]} == "$label" ]] && { printf '%s' "${FORM_VALUES[i]}"; return 0; }
  done
  printf ''
}

_form_cycle() {
  local idx=$1 dir=$2
  local IFS='|'
  local -a choices=()
  read -r -a choices <<<"${FORM_CHOICES[idx]}"
  (( ${#choices[@]} > 0 )) || return 0
  local cur=0 i
  for (( i = 0; i < ${#choices[@]}; i++ )); do
    [[ ${choices[i]} == "${FORM_VALUES[idx]}" ]] && { cur=$i; break; }
  done
  cur=$(( (cur + dir + ${#choices[@]}) % ${#choices[@]} ))
  FORM_VALUES[idx]=${choices[cur]}
}

# form_run <title> [footer_hint]
# Returns 0 on submit, 1 on cancel.
form_run() {
  local title=$1 footer=${2:-"tab/↑↓ move • enter edit • ←→ toggle • ^S or F2 to SAVE • esc cancel"}
  local count=${#FORM_LABELS[@]}
  (( count > 0 )) || return 1

  local idx=0 label_w=0 i
  for (( i = 0; i < count; i++ )); do
    (( ${#FORM_LABELS[i]} > label_w )) && label_w=${#FORM_LABELS[i]}
  done

  local width visible offset=0
  FORM_SUBMITTED=false

  while true; do
    width=$(( label_w + 46 ))
    (( width > TERM_COLS - 4 )) && width=$(( TERM_COLS - 4 ))
    modal_geometry $(( count + 6 )) "$width"
    visible=$(( MODAL_H - 5 ))
    (( visible < 1 )) && visible=1

    (( idx < offset )) && offset=$idx
    (( idx >= offset + visible )) && offset=$(( idx - visible + 1 ))

    "$TUI_BASE_RENDERER"
    clear_rect "$MODAL_TOP" "$MODAL_LEFT" "$MODAL_H" "$MODAL_W"
    draw_box "$MODAL_TOP" "$MODAL_LEFT" "$MODAL_H" "$MODAL_W" "$title" "$C_ACCENT"

    local r value_w=$(( MODAL_W - label_w - 8 ))
    for (( r = 0; r < visible; r++ )); do
      local fi=$(( offset + r ))
      local row=$(( MODAL_TOP + 1 + r ))
      (( fi < count )) || { frame_line "$row" $(( MODAL_LEFT + 2 )) "$(repeat ' ' $(( MODAL_W - 4 )))"; continue; }

      local shown=${FORM_VALUES[fi]}
      case ${FORM_TYPES[fi]} in
        password) shown=$(repeat '*' "${#shown}") ;;
        toggle|select) shown="${G_ARROW} ${shown}" ;;
        # `note` is a read-only informational row. It previously blanked its own
        # value, which made the rows that name the target account and explain
        # why an override is required render as empty — exactly the information
        # the row exists to convey.
        note) : ;;
      esac
      [[ -z $shown && ${FORM_TYPES[fi]} != note ]] && shown="${C_MUTED}—${C_RESET}"

      if (( fi == idx )); then
        frame_line "$row" $(( MODAL_LEFT + 2 )) \
          "${C_KEY}$(cell "${FORM_LABELS[fi]}" "$label_w")${C_RESET} ${C_SEL} $(cell "$(strip_ansi "$shown")" "$value_w") ${C_RESET}"
      else
        frame_line "$row" $(( MODAL_LEFT + 2 )) \
          "${C_MUTED}$(cell "${FORM_LABELS[fi]}" "$label_w")${C_RESET}  ${C_FG}$(cell "$(strip_ansi "$shown")" $(( value_w + 1 )))${C_RESET}"
      fi
    done

    local hint=${FORM_HINTS[idx]:-}
    frame_line $(( MODAL_TOP + MODAL_H - 3 )) $(( MODAL_LEFT + 2 )) \
      "${C_INFO}$(cell "$hint" $(( MODAL_W - 4 )))${C_RESET}"
    frame_line $(( MODAL_TOP + MODAL_H - 2 )) $(( MODAL_LEFT + 2 )) \
      "${C_MUTED}$(fit "$footer" $(( MODAL_W - 4 )))${C_RESET}"
    frame_flush

    read_key || continue
    case $KEY in
      TAB|DOWN)  idx=$(( (idx + 1) % count )) ;;
      BTAB|UP)   idx=$(( (idx - 1 + count) % count )) ;;
      LEFT)      [[ ${FORM_TYPES[idx]} == toggle || ${FORM_TYPES[idx]} == select ]] && _form_cycle "$idx" -1 ;;
      RIGHT)     [[ ${FORM_TYPES[idx]} == toggle || ${FORM_TYPES[idx]} == select ]] && _form_cycle "$idx" 1 ;;
      SPACE)     [[ ${FORM_TYPES[idx]} == toggle || ${FORM_TYPES[idx]} == select ]] && _form_cycle "$idx" 1 ;;
      ENTER)
        case ${FORM_TYPES[idx]} in
          toggle|select) _form_cycle "$idx" 1 ;;
          note) : ;;
          password)
            if input_box "${FORM_LABELS[idx]}" "Enter value (hidden):" "" yes; then
              FORM_VALUES[idx]=$INPUT_RESULT
            fi
            ;;
          *)
            if input_box "${FORM_LABELS[idx]}" "${FORM_HINTS[idx]:-Enter value:}" "${FORM_VALUES[idx]}"; then
              FORM_VALUES[idx]=$INPUT_RESULT
            fi
            ;;
        esac
        ;;
      C-s|M-s|'CSI:Q'|'SS3:Q'|'CSI:1;2Q'|'SS3:P'|'CSI:11~'|'CSI:12~')
        FORM_SUBMITTED=true
        return 0
        ;;
      ESC) FORM_SUBMITTED=false; return 1 ;;
    esac
  done
}
