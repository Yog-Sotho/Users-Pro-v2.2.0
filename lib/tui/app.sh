#!/usr/bin/env bash
# =============================================================================
# lib/tui/app.sh — The application: a two-pane account browser with an
# always-visible detail panel, modal forms for every mutation, and a status bar.
#
# Rendering is pull-based: state changes set NEEDS_REDRAW and the loop paints a
# single frame. Expensive lookups (chage, sshd -T, du) are deferred until the
# user stops moving, so holding an arrow key stays instant.
# =============================================================================

# shellcheck disable=SC2034
# SC2034: this module sets library-owned globals (PASSWORD, ASSUME_YES,
# QUIET, LOG_TO_STDERR, SHOW_OP_OUTPUT, TUI_BASE_RENDERER) that are read in
# lib/core.sh and lib/tui/widgets.sh.

[[ -n ${_USERS_PRO_APP_LOADED:-} ]] && return 0
_USERS_PRO_APP_LOADED=1

# --- State -------------------------------------------------------------------

declare -a ROWS=()            # username:uid:gid:gecos:home:shell
declare -a ROW_USER=()        # parallel: username only
declare -A STATE_CACHE=()     # username -> state label
declare -a DETAIL=()          # rendered right-hand pane lines

SEL=0
SCROLL=0
FILTER=""
SHOW_SYSTEM=false
FILTER_MODE=false
RUNNING=true
NEEDS_REDRAW=true
DETAIL_DIRTY=true
DETAIL_SCROLL=0
STATUS_TEXT=""
STATUS_COLOR=""
STATUS_UNTIL=0
LIST_WIDTH=34
READ_ONLY=false

# =============================================================================
# Status line
# =============================================================================

toast() {
  STATUS_TEXT=$1
  STATUS_COLOR=${2:-$C_INFO}
  STATUS_UNTIL=$(( $(date +%s) + 6 ))
  NEEDS_REDRAW=true
}

toast_ok()   { toast "${G_CHECK} $1" "$C_OK"; }
toast_err()  { toast "${G_CROSS} $1" "$C_ERR"; }
toast_warn() { toast "! $1" "$C_WARN"; }

# =============================================================================
# Data
# =============================================================================

reload_users() {
  local include=no
  [[ $SHOW_SYSTEM == true ]] && include=yes
  ROWS=()
  ROW_USER=()
  STATE_CACHE=()

  local line username gecos
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    username=${line%%:*}
    gecos=$(cut -d: -f4 <<<"$line")
    if [[ -n $FILTER ]]; then
      [[ ${username,,} == *"${FILTER,,}"* || ${gecos,,} == *"${FILTER,,}"* ]] || continue
    fi
    ROWS+=("$line")
    ROW_USER+=("$username")
  done < <(list_users "$include")

  (( SEL >= ${#ROWS[@]} )) && SEL=$(( ${#ROWS[@]} - 1 ))
  (( SEL < 0 )) && SEL=0
  DETAIL_DIRTY=true
  NEEDS_REDRAW=true
}

current_user() {
  (( ${#ROW_USER[@]} > 0 )) || { printf ''; return 1; }
  printf '%s' "${ROW_USER[SEL]}"
}

cached_state() {
  local u=$1
  [[ -n ${STATE_CACHE[$u]:-} ]] || STATE_CACHE[$u]=$(user_state_label "$u")
  printf '%s' "${STATE_CACHE[$u]}"
}

state_color() {
  case $1 in
    ACTIVE)   printf '%s' "$C_OK" ;;
    LOCKED)   printf '%s' "$C_ERR" ;;
    DISABLED) printf '%s' "$C_ERR" ;;
    EXPIRED) printf '%s' "$C_WARN" ;;
    NOPASS)  printf '%s' "$C_WARN" ;;
    *)       printf '%s' "$C_MUTED" ;;
  esac
}

detail_row() { DETAIL+=("$1|$2"); }
detail_gap() { DETAIL+=("|"); }
detail_head() { DETAIL+=("@|$1"); }

build_detail() {
  DETAIL=()
  local username
  username=$(current_user) || { DETAIL+=("@|No accounts match the filter."); return 0; }

  local uid gid gecos home shell primary supp state
  IFS=: read -r _ uid gid gecos home shell <<<"${ROWS[SEL]}"
  primary=$(user_primary_group "$username")
  supp=$(user_supplementary_groups "$username" | paste -sd' ' - 2>/dev/null || true)
  state=$(cached_state "$username")

  detail_head "IDENTITY"
  detail_row "user"        "$username"
  detail_row "uid / gid"   "${uid} / ${gid}"
  detail_row "full name"   "${gecos:-—}"
  detail_row "home"        "${home:-—}"
  detail_row "shell"       "${shell:-—}"
  detail_row "primary grp" "${primary:-—}"
  detail_row "groups"      "${supp:-—}"
  if is_privileged_user "$username"; then
    detail_row "privileged" "YES"
  else
    detail_row "privileged" "no"
  fi
  user_has_sudoers_file "$username" && detail_row "sudoers" "NOPASSWD drop-in present"

  detail_gap
  detail_head "PASSWORD"
  detail_row "state"       "$state"
  detail_row "last change" "$(user_password_last_change "$username")"
  detail_row "expires"     "$(user_expiry "$username")"

  detail_gap
  detail_head "SSH"
  if ssh_installed; then
    local pw_auth pk_auth
    pw_auth=$(get_effective_ssh_option "$username" passwordauthentication || true)
    pk_auth=$(get_effective_ssh_option "$username" pubkeyauthentication || true)
    detail_row "password auth" "${pw_auth:-unknown}"
    detail_row "pubkey auth"   "${pk_auth:-unknown}"
    detail_row "authorized keys" "$(ssh_key_count "$username")"
    detail_row "service"       "$(ssh_service_state)"
  else
    detail_row "openssh-server" "not installed"
  fi

  detail_gap
  detail_head "RUNTIME"
  detail_row "processes"  "$(user_proc_count "$username")"
  detail_row "home size"  "$(user_home_size "$home")"
  detail_row "last login" "$(fit "$(user_last_login "$username")" 60)"
}

# =============================================================================
# Rendering
# =============================================================================

render() {
  frame_begin
  term_size

  local body_top=2
  local body_rows=$(( TERM_ROWS - 3 ))
  (( body_rows < 3 )) && body_rows=3
  LIST_WIDTH=$(( TERM_COLS / 3 ))
  (( LIST_WIDTH < 28 )) && LIST_WIDTH=28
  (( LIST_WIDTH > 46 )) && LIST_WIDTH=46
  (( LIST_WIDTH > TERM_COLS - 30 )) && LIST_WIDTH=$(( TERM_COLS - 30 ))
  (( LIST_WIDTH < 20 )) && LIST_WIDTH=20

  render_header
  render_list "$body_top" "$body_rows"
  render_detail "$body_top" "$body_rows"
  render_status
  render_keybar
  frame_flush
}

render_header() {
  local host badge="" mode=""
  host=$(hostname 2>/dev/null || printf 'localhost')
  [[ $DRY_RUN == true ]] && badge="  ${C_WARN}${C_REV} DRY-RUN ${C_RESET}${C_BAR}"
  if [[ $READ_ONLY == true ]]; then
    mode="${C_WARN}read-only${C_RESET}${C_BAR}"
  else
    mode="${C_OK}root${C_RESET}${C_BAR}"
  fi
  local left=" users-pro ${USERS_PRO_VERSION}  ${G_DOT}  ${host} "
  local noun="accounts"
  (( ${#ROWS[@]} == 1 )) && noun="account"
  local right=" ${mode}  ${G_DOT}  ${#ROWS[@]} ${noun} "
  local plain_right=" read-only  ${G_DOT}  ${#ROWS[@]} ${noun} "
  [[ $READ_ONLY == false ]] && plain_right=" root  ${G_DOT}  ${#ROWS[@]} ${noun} "
  local pad=$(( TERM_COLS - ${#left} - ${#plain_right} ))
  (( pad < 0 )) && pad=0
  frame_line 1 1 "${C_BAR}${C_BOLD}${left}${C_RESET}${C_BAR}${badge}$(repeat ' ' "$pad")${right}${C_RESET}"
}

render_list() {
  local top=$1 rows=$2
  local inner=$(( rows - 2 ))
  (( inner < 1 )) && inner=1

  local title="Accounts"
  [[ -n $FILTER ]] && title="Accounts  /${FILTER}"
  [[ $SHOW_SYSTEM == true ]] && title+="  [+system]"
  draw_box "$top" 1 "$rows" "$LIST_WIDTH" "$title" "$C_BORDER"

  (( SEL < SCROLL )) && SCROLL=$SEL
  (( SEL >= SCROLL + inner )) && SCROLL=$(( SEL - inner + 1 ))
  (( SCROLL < 0 )) && SCROLL=0

  local content_w=$(( LIST_WIDTH - 4 ))
  local r
  for (( r = 0; r < inner; r++ )); do
    local i=$(( SCROLL + r ))
    local row=$(( top + 1 + r ))
    if (( i >= ${#ROWS[@]} )); then
      frame_line "$row" 2 "$(repeat ' ' $(( LIST_WIDTH - 2 )))"
      continue
    fi

    local username uid state scolor mark
    username=${ROW_USER[i]}
    uid=$(cut -d: -f2 <<<"${ROWS[i]}")
    state=$(cached_state "$username")
    scolor=$(state_color "$state")
    case $state in
      LOCKED|DISABLED) mark="${G_CROSS}" ;;
      EXPIRED)         mark="!" ;;
      ACTIVE)          mark="${G_CHECK}" ;;
      *)               mark="${G_DOT}" ;;
    esac

    local name_w=$(( content_w - 10 ))
    (( name_w < 6 )) && name_w=6
    local label
    label="$(cell "$username" "$name_w") $(cell "$uid" 6)"

    if (( i == SEL )); then
      frame_line "$row" 2 "${C_SEL} ${mark} ${label} ${C_RESET}"
    else
      frame_line "$row" 2 " ${scolor}${mark}${C_RESET} ${C_FG}${label}${C_RESET} "
    fi
  done

  # Scroll indicator
  if (( ${#ROWS[@]} > inner )); then
    local pct=$(( (SEL * 100) / (${#ROWS[@]} > 1 ? ${#ROWS[@]} - 1 : 1) ))
    frame_line $(( top + rows - 1 )) $(( LIST_WIDTH - 10 )) \
      "${C_BORDER}${G_H}${C_MUTED} ${pct}% ${C_BORDER}${G_H}${C_RESET}"
  fi
}

render_detail() {
  local top=$1 rows=$2
  local left=$(( LIST_WIDTH + 2 ))
  local width=$(( TERM_COLS - left ))
  (( width < 20 )) && return 0

  local username
  username=$(current_user) || username="—"
  draw_box "$top" "$left" "$rows" "$width" "$username" "$C_BORDER"

  local inner=$(( rows - 2 ))
  local content_w=$(( width - 4 ))
  local label_w=16
  (( content_w < 30 )) && label_w=10

  # Clamp the scroll offset to whatever actually overflows.
  local overflow=$(( ${#DETAIL[@]} - inner ))
  (( overflow < 0 )) && overflow=0
  (( DETAIL_SCROLL > overflow )) && DETAIL_SCROLL=$overflow
  (( DETAIL_SCROLL < 0 )) && DETAIL_SCROLL=0

  local r
  for (( r = 0; r < inner; r++ )); do
    local row=$(( top + 1 + r ))
    local di=$(( r + DETAIL_SCROLL ))
    if (( di >= ${#DETAIL[@]} )); then
      frame_line "$row" $(( left + 1 )) "$(repeat ' ' $(( width - 2 )))"
      continue
    fi
    local entry=${DETAIL[di]}
    local key=${entry%%|*}
    local val=${entry#*|}

    if [[ $key == "@" ]]; then
      frame_line "$row" $(( left + 2 )) \
        "${C_TITLE}$(cell "$val" "$content_w")${C_RESET}"
    elif [[ -z $key && -z $val ]]; then
      frame_line "$row" $(( left + 1 )) "$(repeat ' ' $(( width - 2 )))"
    else
      local vcolor=$C_FG
      case $val in
        LOCKED|DISABLED|YES|*NOPASSWD*) vcolor=$C_ERR ;;
        ACTIVE|yes) vcolor=$C_OK ;;
        EXPIRED|NOPASS|unknown|"not installed") vcolor=$C_WARN ;;
      esac
      frame_line "$row" $(( left + 2 )) \
        "${C_MUTED}$(cell "$key" "$label_w")${C_RESET}${vcolor}$(cell "$val" $(( content_w - label_w )))${C_RESET}"
    fi
  done

  if (( overflow > 0 )); then
    frame_line $(( top + rows - 1 )) $(( left + width - 22 )) \
      "${C_BORDER}${G_H}${C_MUTED} [ ] $(( DETAIL_SCROLL + 1 ))-$(( DETAIL_SCROLL + inner ))/${#DETAIL[@]} ${C_BORDER}${G_H}${C_RESET}"
  fi
  return 0
}

render_status() {
  local row=$(( TERM_ROWS - 1 ))
  local text=$STATUS_TEXT color=$STATUS_COLOR
  if [[ $FILTER_MODE == true ]]; then
    text="filter: ${FILTER}${G_BLOCK}"
    color=$C_ACCENT
  elif [[ -z $text ]]; then
    text="${G_DOT} ? for help"
    color=$C_MUTED
  fi
  frame_line "$row" 1 "${color}$(cell " ${text}" "$TERM_COLS")${C_RESET}"
}

render_keybar() {
  local keys=(
    "a:add" "e:edit" "d:del" "p:passwd" "L:lock" "g:groups"
    "k:keys" "s:ssh" "x:disable" "/:filter" "r:reload" "q:quit"
  )
  local out="" k
  for k in "${keys[@]}"; do
    out+="${C_KEY}${k%%:*}${C_RESET}${C_BAR}${C_MUTED}·${k#*:}${C_RESET}${C_BAR}  "
  done
  local plain=""
  for k in "${keys[@]}"; do plain+="${k%%:*}·${k#*:}  "; done
  local pad=$(( TERM_COLS - ${#plain} - 1 ))
  (( pad < 0 )) && pad=0
  frame_line "$TERM_ROWS" 1 "${C_BAR} ${out}$(repeat ' ' "$pad")${C_RESET}"
}

render_base() { render; }

# =============================================================================
# Operation runner
# =============================================================================
# Mutations live in lib/account.sh and end in die() on failure. die() calls
# exit, which would tear down the UI — so each runs inside a command
# substitution with the traps detached. Output is captured and surfaced in a
# modal instead of being scribbled across the framebuffer.

# TUI_RUN_RC carries the last operation's status. tui_run itself always
# returns 0 — see the note above the return.
TUI_RUN_RC=0

tui_run() {
  local desc=$1
  shift
  local out="" rc=0
  out=$(
    trap - EXIT ERR
    LOG_TO_STDERR=true
    QUIET=false
    ASSUME_YES=true
    "$@" 2>&1
  ) || rc=$?

  local -a lines=()
  [[ -n $out ]] && mapfile -t lines <<<"$out"

  if (( rc == 0 )); then
    toast_ok "$desc"
    if (( ${#lines[@]} > 0 )) && [[ ${SHOW_OP_OUTPUT:-true} == true ]]; then
      msg_box "Done — ${desc}" "$C_OK" "${lines[@]}"
    fi
  else
    toast_err "${desc} failed"
    if (( ${#lines[@]} == 0 )); then
      lines=("The operation failed with exit code ${rc}.")
    fi
    msg_box "Failed — ${desc}" "$C_ERR" "${lines[@]}"
  fi

  STATE_CACHE=()
  reload_users

  # CRITICAL: return 0 unconditionally, and expose the status via TUI_RUN_RC.
  #
  # A failed operation has already been reported to the user in a modal. If the
  # status were propagated instead, it would escape the action handler, cross
  # the `case` arm in handle_key() — which is NOT a protected context — and trip
  # `set -e`, killing the whole interface. That is precisely what happened when
  # deleting a privileged account without force: the guard fired correctly, the
  # modal rendered correctly, and then dismissing it exited the app with 77.
  #
  # An event loop must survive its handlers. Callers that care read TUI_RUN_RC.
  TUI_RUN_RC=$rc
  return 0
}

# tui_ok — did the most recent tui_run succeed?
tui_ok() { (( TUI_RUN_RC == 0 )); }

require_write() {
  if [[ $READ_ONLY == true ]]; then
    msg_box "Root required" "$C_WARN" \
      "users-pro is running without root privileges." \
      "Browsing is available; modifications are not." \
      "" "Restart with: sudo users-pro tui"
    return 1
  fi
  return 0
}

# =============================================================================
# Actions
# =============================================================================

action_add() {
  require_write || return 0

  local -a shells=()
  mapfile -t shells < <(list_shells)
  local shell_choices
  shell_choices=$(printf '%s|' "${shells[@]}")
  shell_choices=${shell_choices%|}

  form_reset
  form_add "username"    ""            text     ""                    "Lowercase, starts with a letter or underscore, max 32 chars"
  form_add "full name"   ""            text     ""                    "GECOS / comment field. Optional."
  form_add "shell"       "/bin/bash"   select   "$shell_choices"      "←/→ to cycle through the shells in /etc/shells"
  form_add "groups"      ""            text     ""                    "Comma-separated supplementary groups. Optional."
  form_add "password"    ""            password ""                    "Leave blank to create the account with a locked password"
  form_add "generate pw" "no"          toggle   "no|yes"              "Generate a 20-character password instead of typing one"
  form_add "ssh pw auth" "auto"        toggle   "auto|yes|no"         "auto applies it only when openssh-server is installed"
  form_add "sudo NOPASSWD" "no"        toggle   "no|yes"              "Installs a sudoers drop-in. Grants full root without a prompt."
  form_add "allow privileged" "no"     toggle   "no|yes"              "Required to place the account in sudo/admin/wheel/root"
  form_add "expire date" ""            text     ""                    "YYYY-MM-DD, or blank for never"

  form_run "Create account" || { toast "Cancelled"; return 0; }

  local username shell groups gecos pw genpw sshauth sudonp allowpriv expire
  username=$(form_value_of "username")
  gecos=$(form_value_of "full name")
  shell=$(form_value_of "shell")
  groups=$(form_value_of "groups")
  pw=$(form_value_of "password")
  genpw=$(form_value_of "generate pw")
  sshauth=$(form_value_of "ssh pw auth")
  sudonp=$(form_value_of "sudo NOPASSWD")
  allowpriv=$(form_value_of "allow privileged")
  expire=$(form_value_of "expire date")

  [[ -n $username ]] || { toast_err "A username is required"; return 0; }

  if [[ $sudonp == yes ]]; then
    confirm_box "Passwordless sudo" \
      "This grants '${username}' unrestricted root access with no password prompt. Continue?" yes ||
      { toast "Cancelled"; return 0; }
  fi

  local generated=""
  if [[ $genpw == yes ]]; then
    generated=$(generate_password 20)
    PASSWORD=$generated
  else
    PASSWORD=$pw
  fi

  SHOW_OP_OUTPUT=true
  tui_run "create ${username}" account_create \
    "$username" "$shell" "$gecos" "$groups" "$sshauth" "$allowpriv" \
    "" "" "$expire" "$sudonp"
  local rc=$TUI_RUN_RC
  PASSWORD=""

  if (( rc == 0 )) && [[ -n $generated ]]; then
    msg_box "Generated password" "$C_WARN" \
      "Account: ${username}" \
      "Password: ${generated}" \
      "" "This is shown once. Copy it now."
    generated=""
  fi

  # Jump to the account that was just created.
  local i
  for (( i = 0; i < ${#ROW_USER[@]}; i++ )); do
    [[ ${ROW_USER[i]} == "$username" ]] && { SEL=$i; break; }
  done
  DETAIL_DIRTY=true
  return 0
}

# delete_blockers <username> — the specific reasons account_delete will refuse.
# Computed up front so the form can state them plainly instead of letting the
# user discover them by being rejected.
delete_blockers() {
  local username=$1 uid procs
  uid=$(user_uid "$username")
  [[ -n $uid ]] && (( uid < 1000 )) && printf 'system account (uid %s)\n' "$uid"
  is_privileged_user "$username" && printf 'member of a privileged group\n'
  procs=$(user_proc_count "$username")
  (( procs > 0 )) && printf '%s running process(es)\n' "$procs"
  return 0
}

action_delete() {
  require_write || return 0
  local username
  username=$(current_user) || return 0

  if is_protected_user "$username"; then
    msg_box "Protected" "$C_ERR" "'${username}' is a protected system account and cannot be deleted."
    return 0
  fi

  local uid privileged="no" procs
  uid=$(user_uid "$username")
  is_privileged_user "$username" && privileged=yes
  procs=$(user_proc_count "$username")

  local -a blockers=()
  mapfile -t blockers < <(delete_blockers "$username")

  local force_default="no" force_hint="Not needed for this account"
  if (( ${#blockers[@]} > 0 )); then
    # The account cannot be deleted without force. Default it to yes rather
    # than making the user fail once, read an error, hunt for the toggle, and
    # try again. The typed-name confirmation is what guards the destructive
    # step; burying the override behind a rejection guards nothing.
    force_default="yes"
    force_hint="REQUIRED here: $(printf '%s; ' "${blockers[@]}")"
    force_hint=${force_hint%; }
  fi

  form_reset
  form_add "account"     "$username" note ""          ""
  if (( ${#blockers[@]} > 0 )); then
    local blocked_summary
    blocked_summary=$(printf '%s; ' "${blockers[@]}")
    form_add "needs force" "${blocked_summary%; }" note "" ""
  fi
  form_add "keep home"   "no"        toggle "no|yes"  "Retain the home directory after deletion"
  form_add "backup home" ""          text   ""        "Archive path, e.g. /var/backups/${username}.tar.gz (created 0600)"
  form_add "purge /tmp"  "no"        toggle "no|yes"  "Also delete files owned by this user in /tmp and /var/tmp"
  form_add "force"       "$force_default" toggle "yes|no" "$force_hint"

  form_run "Delete account — ${username}" || { toast "Cancelled"; return 0; }

  local keep backup purge force
  keep=$(form_value_of "keep home")
  backup=$(form_value_of "backup home")
  purge=$(form_value_of "purge /tmp")
  force=$(form_value_of "force")

  local warn="UID ${uid}."
  [[ $privileged == yes ]] && warn+=" This account is PRIVILEGED."
  (( procs > 0 )) && warn+=" ${procs} process(es) are running and will be killed."
  [[ $keep == no ]] && warn+=" The home directory will be destroyed."

  danger_box "Confirm deletion" \
    "${warn} There is no undo." "$username" || { toast "Cancelled"; return 0; }

  SHOW_OP_OUTPUT=true
  tui_run "delete ${username}" account_delete "$username" "$force" "$keep" "$backup" "$purge"

  # A refusal that force would resolve should offer the override, not describe
  # it. EX_NOPERM (77) and EX_CONFLICT (79) are exactly those cases.
  if ! tui_ok && [[ $force != yes ]] &&
     { (( TUI_RUN_RC == 77 )) || (( TUI_RUN_RC == 79 )); }; then
    local reasons=""
    (( ${#blockers[@]} > 0 )) && reasons=" ($(printf '%s; ' "${blockers[@]}"))"
    reasons=${reasons%; )}
    [[ -n $reasons && $reasons != *")" ]] && reasons+=")"
    if confirm_box "Retry with force?" \
         "'${username}' was refused${reasons}. Retry the deletion with force enabled?" yes; then
      tui_run "delete ${username} (forced)" account_delete "$username" yes "$keep" "$backup" "$purge"
    fi
  fi
  return 0
}

action_edit() {
  require_write || return 0
  local username
  username=$(current_user) || return 0

  local -a shells=()
  mapfile -t shells < <(list_shells)
  local shell_choices cur_shell cur_gecos cur_home
  cur_shell=$(user_shell "$username")
  cur_gecos=$(user_gecos "$username")
  cur_home=$(user_home "$username")
  shell_choices=$(printf '%s|' "${shells[@]}")
  shell_choices=${shell_choices%|}
  [[ $shell_choices == *"$cur_shell"* ]] || shell_choices="${cur_shell}|${shell_choices}"

  form_reset
  form_add "full name"    "$cur_gecos"  text   ""                "GECOS / comment field"
  form_add "shell"        "$cur_shell"  select "$shell_choices"  "←/→ to cycle"
  form_add "home"         "$cur_home"   text   ""                "Changing this does not move files unless 'move home' is yes"
  form_add "move home"    "no"          toggle "no|yes"          "Relocate the existing contents to the new path"
  form_add "expire date"  ""            text   ""                "YYYY-MM-DD, or -1 to clear. Blank leaves it unchanged."
  form_add "min days"     ""            text   ""                "Minimum password age. Blank leaves it unchanged."
  form_add "max days"     ""            text   ""                "Maximum password age. Blank leaves it unchanged."
  form_add "warn days"    ""            text   ""                "Warning window before expiry"
  form_add "force change" "no"          toggle "no|yes"          "Require a new password at next login"
  form_add "ssh pw auth"  ""            select "|yes|no"         "Blank leaves the current sshd setting alone"
  form_add "sudo NOPASSWD" ""           select "|yes|no"         "Blank leaves the sudoers drop-in alone"
  form_add "force"        "no"          toggle "no|yes"          "Permit editing a system account (uid < 1000)"

  form_run "Edit ${username}" || { toast "Cancelled"; return 0; }

  local gecos shell home movehome expire mind maxd warnd forcechg sshauth sudonp force
  gecos=$(form_value_of "full name")
  shell=$(form_value_of "shell")
  home=$(form_value_of "home")
  movehome=$(form_value_of "move home")
  expire=$(form_value_of "expire date")
  mind=$(form_value_of "min days")
  maxd=$(form_value_of "max days")
  warnd=$(form_value_of "warn days")
  forcechg=$(form_value_of "force change")
  sshauth=$(form_value_of "ssh pw auth")
  sudonp=$(form_value_of "sudo NOPASSWD")
  force=$(form_value_of "force")

  SHOW_OP_OUTPUT=false
  local applied=0

  [[ $gecos != "$cur_gecos" ]] && { tui_run "update comment" account_set_comment "$username" "$gecos"; applied=1; }
  [[ $shell != "$cur_shell" ]] && { tui_run "change shell" account_set_shell "$username" "$shell"; applied=1; }
  if [[ -n $home && $home != "$cur_home" ]]; then
    tui_run "change home" account_set_home "$username" "$home" "$movehome"; applied=1
  fi
  [[ -n $expire ]] && { tui_run "set expiry" account_set_expiry "$username" "$expire"; applied=1; }
  if [[ -n $mind || -n $maxd || -n $warnd ]]; then
    tui_run "set password aging" account_set_aging "$username" "$mind" "$maxd" "$warnd" ""
    applied=1
  fi
  [[ $forcechg == yes ]] && { tui_run "force password change" account_force_password_change "$username"; applied=1; }
  [[ -n $sshauth ]] && { tui_run "set ssh password auth" configure_ssh_password_auth "$username" "$sshauth"; applied=1; }
  [[ -n $sudonp ]] && {
    if [[ $sudonp == yes ]]; then
      confirm_box "Passwordless sudo" \
        "Grant '${username}' unrestricted root access with no password prompt?" yes &&
        { tui_run "grant NOPASSWD sudo" account_set_sudo_nopasswd "$username" yes; applied=1; }
    else
      tui_run "revoke NOPASSWD sudo" account_set_sudo_nopasswd "$username" no
      applied=1
    fi
  }

  SHOW_OP_OUTPUT=true
  if (( applied == 1 )); then toast_ok "Updated ${username}"; else toast "No changes"; fi
  DETAIL_DIRTY=true
  return 0
}

action_password() {
  require_write || return 0
  local username
  username=$(current_user) || return 0

  form_reset
  form_add "account"  "$username" note     ""       ""
  form_add "method"   "type"      toggle   "type|generate" "←/→ to choose between typing a password and generating one"
  form_add "password" ""          password ""       "Ignored when the method is 'generate'"
  form_add "force change at next login" "no" toggle "no|yes" ""
  form_run "Set password" || { toast "Cancelled"; return 0; }

  local method pw forcechg generated=""
  method=$(form_value_of "method")
  pw=$(form_value_of "password")
  forcechg=$(form_value_of "force change at next login")

  if [[ $method == generate ]]; then
    generated=$(generate_password 20)
    PASSWORD=$generated
  else
    [[ -n $pw ]] || { toast_err "Password was empty"; return 0; }
    local -a issues=()
    mapfile -t issues < <(password_strength_issues "$pw" "$username")
    if (( ${#issues[@]} > 0 )); then
      local -a body=("This password is weak:")
      local i
      for i in "${issues[@]}"; do body+=("  ${G_DOT} ${i}"); done
      body+=("" "Use it anyway?")
      confirm_box "Weak password" "${body[*]}" || { toast "Cancelled"; return 0; }
    fi
    PASSWORD=$pw
  fi

  SHOW_OP_OUTPUT=false
  tui_run "set password for ${username}" set_user_password "$username"
  if tui_ok; then
    [[ $forcechg == yes ]] && tui_run "force change" account_force_password_change "$username"
    if [[ -n $generated ]]; then
      msg_box "Generated password" "$C_WARN" \
        "Account: ${username}" "Password: ${generated}" "" "Shown once. Copy it now."
    fi
  fi
  PASSWORD=""
  generated=""
  SHOW_OP_OUTPUT=true
  return 0
}

action_toggle_lock() {
  require_write || return 0
  local username state
  username=$(current_user) || return 0
  state=$(user_password_status "$username")

  SHOW_OP_OUTPUT=false
  if [[ $state == locked ]]; then
    tui_run "unlock ${username}" account_unlock "$username"
  else
    confirm_box "Lock account" "Lock the password for '${username}'? They will not be able to log in with a password." ||
      { toast "Cancelled"; SHOW_OP_OUTPUT=true; return 0; }
    tui_run "lock ${username}" account_lock "$username"
  fi
  SHOW_OP_OUTPUT=true
  return 0
}

action_groups() {
  require_write || return 0
  local username
  username=$(current_user) || return 0

  local current
  current=$(user_supplementary_groups "$username" | paste -sd, - 2>/dev/null || true)

  form_reset
  form_add "account"      "$username" note   ""       ""
  form_add "current"      "${current:-none}" note "" ""
  form_add "add"          ""          text   ""       "Comma-separated groups to append"
  form_add "remove"       ""          text   ""       "Comma-separated groups to remove"
  form_add "replace with" ""          text   ""       "Comma-separated. Overrides add/remove. '-' clears every supplementary group."
  form_add "allow privileged" "no"    toggle "no|yes" "Required for sudo/admin/wheel/root"
  form_run "Groups — ${username}" || { toast "Cancelled"; return 0; }

  local add rm replace allow
  add=$(form_value_of "add")
  rm=$(form_value_of "remove")
  replace=$(form_value_of "replace with")
  allow=$(form_value_of "allow privileged")

  SHOW_OP_OUTPUT=false
  if [[ -n $replace ]]; then
    if [[ $replace == "-" ]]; then
      confirm_box "Clear groups" "Remove '${username}' from every supplementary group?" ||
        { toast "Cancelled"; SHOW_OP_OUTPUT=true; return 0; }
      tui_run "clear groups" account_clear_supplementary_groups "$username"
    else
      local -a g=()
      mapfile -t g < <(csv_to_lines "$replace")
      tui_run "replace groups" account_set_groups "$username" "$allow" "${g[@]+"${g[@]}"}"
    fi
  else
    if [[ -n $add ]]; then
      local -a ga=()
      mapfile -t ga < <(csv_to_lines "$add")
      tui_run "add groups" account_add_groups "$username" "$allow" "${ga[@]+"${ga[@]}"}"
    fi
    if [[ -n $rm ]]; then
      local -a gr=()
      mapfile -t gr < <(csv_to_lines "$rm")
      tui_run "remove groups" account_remove_groups "$username" "${gr[@]+"${gr[@]}"}"
    fi
  fi
  SHOW_OP_OUTPUT=true
  DETAIL_DIRTY=true
  return 0
}

action_keys() {
  local username
  username=$(current_user) || return 0

  local -a fps=()
  mapfile -t fps < <(ssh_key_fingerprints "$username")
  (( ${#fps[@]} > 0 )) || fps=("(no authorized keys)")

  local -a menu=("View fingerprints" "Add a key" "Add keys from a file" "Remove keys matching text" "Remove all keys")
  select_box "SSH keys — ${username}" "${menu[@]}" || return 0

  case $SELECT_INDEX in
    0) msg_box "Authorized keys — ${username}" "$C_ACCENT" "${fps[@]}" ;;
    1)
      require_write || return 0
      input_box "Add public key" "Paste an OpenSSH public key:" "" || return 0
      [[ -n $INPUT_RESULT ]] || { toast_err "Nothing pasted"; return 0; }
      SHOW_OP_OUTPUT=false
      tui_run "add key" ssh_add_authorized_key "$username" "$INPUT_RESULT"
      SHOW_OP_OUTPUT=true
      ;;
    2)
      require_write || return 0
      input_box "Add keys from file" "Path to a file of public keys:" "" || return 0
      [[ -r $INPUT_RESULT ]] || { toast_err "Cannot read that file"; return 0; }
      local file=$INPUT_RESULT line added=0
      while IFS= read -r line; do
        [[ -z $line || $line == \#* ]] && continue
        tui_run "add key" ssh_add_authorized_key "$username" "$line"
        tui_ok && added=$(( added + 1 ))
      done <"$file"
      toast_ok "Imported ${added} key(s)"
      ;;
    3)
      require_write || return 0
      input_box "Remove keys" "Remove keys containing this text (e.g. a comment):" "" || return 0
      [[ -n $INPUT_RESULT ]] || return 0
      SHOW_OP_OUTPUT=false
      tui_run "remove keys" ssh_remove_authorized_key "$username" "$INPUT_RESULT"
      SHOW_OP_OUTPUT=true
      ;;
    4)
      require_write || return 0
      danger_box "Remove all keys" \
        "Every authorized key for '${username}' will be deleted. Key-based logins will stop working immediately." \
        "$username" || return 0
      SHOW_OP_OUTPUT=false
      tui_run "clear keys" ssh_clear_authorized_keys "$username"
      SHOW_OP_OUTPUT=true
      ;;
  esac
  DETAIL_DIRTY=true
  return 0
}

action_ssh_toggle() {
  require_write || return 0
  local username current target
  username=$(current_user) || return 0
  ssh_installed || { msg_box "OpenSSH" "$C_WARN" "openssh-server is not installed on this host."; return 0; }

  current=$(get_effective_ssh_option "$username" passwordauthentication || printf 'unknown')
  [[ $current == yes ]] && target=no || target=yes

  confirm_box "SSH password auth" \
    "PasswordAuthentication for '${username}' is currently '${current}'. Set it to '${target}'?" ||
    { toast "Cancelled"; return 0; }

  SHOW_OP_OUTPUT=false
  tui_run "ssh password auth ${target}" configure_ssh_password_auth "$username" "$target"
  SHOW_OP_OUTPUT=true
  return 0
}

action_disable_toggle() {
  require_write || return 0
  local username state
  username=$(current_user) || return 0
  state=$(cached_state "$username")

  SHOW_OP_OUTPUT=false
  if [[ $state == LOCKED || $state == EXPIRED || $state == DISABLED ]]; then
    confirm_box "Enable account" "Unlock '${username}', clear the expiry, and restore /bin/bash?" &&
      tui_run "enable ${username}" account_enable "$username" /bin/bash
  else
    danger_box "Disable account" \
      "'${username}' will be locked, expired, and given /usr/sbin/nologin. Running sessions are not terminated." \
      "$username" &&
      tui_run "disable ${username}" account_disable "$username"
  fi
  SHOW_OP_OUTPUT=true
  return 0
}

action_help() {
  msg_box "Keys" "$C_ACCENT" \
    "NAVIGATE   ↑↓ jk move    PgUp/PgDn page    Home/End  first/last" \
    "           [ ] scroll detail        Tab       system accounts" \
    "           /   filter               Esc       clear filter" \
    "           r   reload               q         quit" \
    "" \
    "ACCOUNT    a create      e edit        d delete" \
    "           p password    L lock/unlock g groups" \
    "           x disable / enable (lock + expire + nologin)" \
    "" \
    "SSH        k authorized_keys         s per-user PasswordAuthentication" \
    "" \
    "OTHER      i full report  l audit log  D toggle dry-run  ? help" \
    "" \
    "Destructive actions require typing the account name to confirm."
  return 0
}

action_report() {
  local username out
  username=$(current_user) || return 0
  out=$(trap - EXIT ERR; LOG_TO_STDERR=false; user_report_text "$username" 2>&1 | sed -E $'s/\033\\[[0-9;]*m//g')
  local -a lines=()
  mapfile -t lines <<<"$out"
  msg_box "Report — ${username}" "$C_ACCENT" "${lines[@]:0:$(( TERM_ROWS - 8 ))}"
  return 0
}

action_audit_log() {
  local -a lines=()
  if [[ -r $AUDIT_LOG ]]; then
    mapfile -t lines < <(tail -n $(( TERM_ROWS - 8 )) -- "$AUDIT_LOG")
  fi
  (( ${#lines[@]} > 0 )) || lines=("No audit entries yet at ${AUDIT_LOG}.")
  msg_box "Audit log" "$C_INFO" "${lines[@]}"
  return 0
}

action_toggle_dry_run() {
  if [[ $DRY_RUN == true ]]; then
    DRY_RUN=false
    toast_warn "Dry-run OFF — changes will be applied"
  else
    DRY_RUN=true
    toast_ok "Dry-run ON — nothing will be modified"
  fi
  return 0
}

# =============================================================================
# Input handling
# =============================================================================

handle_filter_key() {
  case $KEY in
    ENTER) FILTER_MODE=false ;;
    ESC)   FILTER_MODE=false; FILTER=""; reload_users ;;
    BACKSPACE) FILTER=${FILTER%?}; reload_users ;;
    C-u)   FILTER=""; reload_users ;;
    SPACE) : ;;
    ?)     [[ $KEY == [[:print:]] ]] && { FILTER+=$KEY; reload_users; } ;;
  esac
  NEEDS_REDRAW=true
}

move_sel() {
  local delta=$1 count=${#ROWS[@]}
  (( count == 0 )) && return 0
  SEL=$(( SEL + delta ))
  (( SEL < 0 )) && SEL=0
  (( SEL > count - 1 )) && SEL=$(( count - 1 ))
  DETAIL_SCROLL=0
  DETAIL_DIRTY=true
  NEEDS_REDRAW=true
}

# dispatch — run an action handler so that no failure can escape into the
# event loop. tui_run already surfaces operation errors in a modal; anything
# else that goes wrong is reported as a toast rather than killing the session.
# Without this, any non-zero status crossing a `case` arm trips `set -e`.
dispatch() {
  local name=$1 rc=0
  shift
  "$name" "$@" || rc=$?
  if (( rc != 0 )); then
    log_error "handler ${name} returned ${rc}"
    toast_err "${name#action_} failed (${rc}) — the session is still running"
  fi
  return 0
}

handle_key() {
  case $KEY in
    q|C-c) RUNNING=false ;;
    UP|k)     move_sel -1 ;;
    DOWN|j)   move_sel 1 ;;
    PGUP)     move_sel -10 ;;
    PGDN)     move_sel 10 ;;
    HOME)     SEL=0; DETAIL_DIRTY=true; NEEDS_REDRAW=true ;;
    END)      SEL=$(( ${#ROWS[@]} - 1 )); (( SEL < 0 )) && SEL=0; DETAIL_DIRTY=true; NEEDS_REDRAW=true ;;
    '[')      DETAIL_SCROLL=$(( DETAIL_SCROLL - 3 )); (( DETAIL_SCROLL < 0 )) && DETAIL_SCROLL=0 ;;
    ']')      DETAIL_SCROLL=$(( DETAIL_SCROLL + 3 )) ;;
    '/')      FILTER_MODE=true; NEEDS_REDRAW=true ;;
    ESC)      [[ -n $FILTER ]] && { FILTER=""; reload_users; } ;;
    TAB)
      [[ $SHOW_SYSTEM == true ]] && SHOW_SYSTEM=false || SHOW_SYSTEM=true
      reload_users
      toast "System accounts: ${SHOW_SYSTEM}"
      ;;
    r|C-r|C-l) STATE_CACHE=(); reload_users; toast_ok "Reloaded" ;;
    a)  dispatch action_add ;;
    e)  dispatch action_edit ;;
    d)  dispatch action_delete ;;
    p)  dispatch action_password ;;
    L)  dispatch action_toggle_lock ;;
    g)  dispatch action_groups ;;
    x)  dispatch action_disable_toggle ;;
    K)  dispatch action_keys ;;
    s)  dispatch action_ssh_toggle ;;
    i)  dispatch action_report ;;
    l)  dispatch action_audit_log ;;
    D)  dispatch action_toggle_dry_run ;;
    '?'|h|F1) dispatch action_help ;;
    *)  return 0 ;;
  esac
  NEEDS_REDRAW=true
}

# =============================================================================
# Main loop
# =============================================================================

app_main() {
  TUI_BASE_RENDERER=render_base
  is_root || READ_ONLY=true

  trap 'on_sigwinch' WINCH

  reload_users
  build_detail
  DETAIL_DIRTY=false

  if [[ $READ_ONLY == true ]]; then
    toast_warn "Running without root — browsing only. Restart with sudo to make changes."
  else
    toast "${#ROWS[@]} account(s) loaded. Press ? for help."
  fi

  while [[ $RUNNING == true ]]; do
    if [[ $NEEDS_REDRAW == true ]]; then
      render
      NEEDS_REDRAW=false
    fi

    if read_key 0.25; then
      # Belt and braces: even the key handlers are called defensively, so a
      # bug in one keystroke path cannot end the session.
      if [[ $FILTER_MODE == true ]]; then
        handle_filter_key || log_error "handle_filter_key returned $?"
      else
        handle_key || log_error "handle_key returned $?"
      fi
    else
      # Idle tick: deferred work happens here so navigation never stalls.
      if [[ $RESIZED == true ]]; then
        RESIZED=false
        term_size
        NEEDS_REDRAW=true
      fi
      if [[ $DETAIL_DIRTY == true ]]; then
        build_detail
        DETAIL_DIRTY=false
        NEEDS_REDRAW=true
      fi
      if [[ -n $STATUS_TEXT ]] && (( $(date +%s) > STATUS_UNTIL )); then
        STATUS_TEXT=""
        NEEDS_REDRAW=true
      fi
    fi
  done
}
