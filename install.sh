#!/usr/bin/env bash
# =============================================================================
# install.sh — Install or remove users-pro system-wide.
# Usage: sudo ./install.sh [--prefix /usr/local] [--uninstall] [--dry-run]
# =============================================================================
set -Eeuo pipefail

SRC_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PREFIX=/usr/local
UNINSTALL=false
DRY=false

say() { printf '%s\n' "$*"; }
run() { if [[ $DRY == true ]]; then printf '  would: %s\n' "$*"; else "$@"; fi; }

while (( $# > 0 )); do
  case $1 in
    --prefix)    PREFIX=${2:?--prefix requires a path}; shift ;;
    --prefix=*)  PREFIX=${1#*=} ;;
    --uninstall) UNINSTALL=true ;;
    --dry-run|-n) DRY=true ;;
    -h|--help)
      sed -n '2,6p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
      exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 64 ;;
  esac
  shift
done

BIN_DIR="${PREFIX}/bin"
LIB_DIR="${PREFIX}/lib/users-pro"
MAN_DIR="${PREFIX}/share/man/man8"
COMP_DIR="/etc/bash_completion.d"

if [[ $DRY == false ]] && (( EUID != 0 )); then
  say "This installer needs root. Re-run with sudo."
  exit 77
fi

if [[ $UNINSTALL == true ]]; then
  say "Removing users-pro from ${PREFIX}..."
  run rm -f -- "${BIN_DIR}/users-pro" "${BIN_DIR}/users-pro-tui"
  run rm -rf -- "$LIB_DIR"
  run rm -f -- "${MAN_DIR}/users-pro.8" "${MAN_DIR}/users-pro.8.gz"
  run rm -f -- "${COMP_DIR}/users-pro"
  say "Done. The audit log at /var/log/users-pro.log was left in place."
  say "Managed sshd drop-ins and sudoers files were NOT removed; review:"
  say "  /etc/ssh/sshd_config.d/99-users-pro-*.conf"
  say "  /etc/sudoers.d/90-users-pro-*"
  exit 0
fi

# --- Preflight ---------------------------------------------------------------
(( BASH_VERSINFO[0] >= 4 )) || { say "bash 4.4+ required."; exit 78; }
for f in bin/users-pro bin/users-pro-tui lib/core.sh lib/account.sh lib/ssh.sh \
         lib/query.sh lib/tui/term.sh lib/tui/input.sh lib/tui/widgets.sh lib/tui/app.sh; do
  [[ -f "${SRC_DIR}/${f}" ]] || { say "Missing source file: ${f}"; exit 78; }
done

say "Installing users-pro to ${PREFIX}..."

run install -d -m 0755 -- "$BIN_DIR" "$LIB_DIR" "${LIB_DIR}/tui" "$MAN_DIR"
run install -m 0644 -- "${SRC_DIR}/lib/core.sh"    "${LIB_DIR}/core.sh"
run install -m 0644 -- "${SRC_DIR}/lib/ssh.sh"     "${LIB_DIR}/ssh.sh"
run install -m 0644 -- "${SRC_DIR}/lib/query.sh"   "${LIB_DIR}/query.sh"
run install -m 0644 -- "${SRC_DIR}/lib/account.sh" "${LIB_DIR}/account.sh"
for f in term input widgets app; do
  run install -m 0644 -- "${SRC_DIR}/lib/tui/${f}.sh" "${LIB_DIR}/tui/${f}.sh"
done

# The binaries resolve their libraries relative to themselves, so an explicit
# USERS_PRO_LIB is baked in for the installed copy. That keeps the repo checkout
# and the installed copy from ever cross-importing.
for b in users-pro users-pro-tui; do
  if [[ $DRY == true ]]; then
    printf '  would: install %s with USERS_PRO_LIB=%s\n' "$b" "$LIB_DIR"
  else
    sed "s|^LIB_DIR=.*|LIB_DIR=\${USERS_PRO_LIB:-${LIB_DIR}}|" \
      "${SRC_DIR}/bin/${b}" >"${BIN_DIR}/${b}.tmp"
    install -m 0755 -- "${BIN_DIR}/${b}.tmp" "${BIN_DIR}/${b}"
    rm -f -- "${BIN_DIR}/${b}.tmp"
  fi
done

[[ -f "${SRC_DIR}/docs/users-pro.8" ]] &&
  run install -m 0644 -- "${SRC_DIR}/docs/users-pro.8" "${MAN_DIR}/users-pro.8"

if [[ -d $COMP_DIR ]] && [[ -f "${SRC_DIR}/docs/users-pro.bash-completion" ]]; then
  run install -m 0644 -- "${SRC_DIR}/docs/users-pro.bash-completion" "${COMP_DIR}/users-pro"
fi

# The audit log is authpriv-grade material: root-owned, group-readable at most.
if [[ $DRY == false ]]; then
  touch /var/log/users-pro.log 2>/dev/null || true
  chmod 0640 /var/log/users-pro.log 2>/dev/null || true
  chown root:adm /var/log/users-pro.log 2>/dev/null ||
    chown root:root /var/log/users-pro.log 2>/dev/null || true
fi

say ""
say "Verifying the installation..."

# An installer that only claims success is useless. Run the thing.
verify_fail=0
if [[ $DRY == true ]]; then
  say "  (skipped: dry run)"
else
  if out=$("${BIN_DIR}/users-pro" --version 2>&1); then
    say "  ok   ${BIN_DIR}/users-pro -> ${out}"
  else
    say "  FAIL ${BIN_DIR}/users-pro did not run: ${out}"
    verify_fail=1
  fi
  if "${BIN_DIR}/users-pro" list >/dev/null 2>&1; then
    say "  ok   library loaded from ${LIB_DIR}"
  else
    say "  FAIL library did not load from ${LIB_DIR}"
    verify_fail=1
  fi
  if [[ -x "${BIN_DIR}/users-pro-tui" ]]; then
    say "  ok   ${BIN_DIR}/users-pro-tui is executable"
  else
    say "  FAIL ${BIN_DIR}/users-pro-tui is missing or not executable"
    verify_fail=1
  fi
fi

# PATH problems are the single most common reason a correct install looks
# broken, so check both the invoking user's PATH and sudo's secure_path.
if [[ $DRY == false ]]; then
  case ":${PATH}:" in
    *":${BIN_DIR}:"*) : ;;
    *) say "  WARN ${BIN_DIR} is not on your PATH; add it or use the full path." ;;
  esac
  if secure_path=$(grep -Eo '^Defaults[[:space:]]+secure_path[[:space:]]*=.*' /etc/sudoers 2>/dev/null); then
    case $secure_path in
      *"${BIN_DIR}"*) : ;;
      *) say "  WARN ${BIN_DIR} is not in sudo's secure_path; 'sudo users-pro' may not resolve." ;;
    esac
  fi
fi

if (( verify_fail != 0 )); then
  say ""
  say "Installation completed with errors. See the FAIL lines above."
  exit 70
fi

say ""
say "Installed and verified. The command is:  users-pro   (note the 's')"
say ""
say "    sudo users-pro tui         launch the interface"
say "    users-pro --help           command reference"
say "    users-pro list             list accounts (no root needed)"
say ""
say "Uninstall with:  sudo ${SRC_DIR}/install.sh --uninstall"
