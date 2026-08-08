<p align="center">
  <img src="assets/banner.svg" alt="Users-Pro.v2.2.0 Banner" width="100%">
</p>


# Users-Pro 2.2.0 by YogSotho

Local account lifecycle management for Ubuntu 26.04 LTS — a full-screen
terminal interface backed by a scriptable CLI.

Zero runtime dependencies beyond `bash` 4.4+ and shadow-utils. No Node, no
Python, no ncurses. It runs on a freshly-provisioned server over SSH, which is
exactly where you need it.

```
 users-pro 2.0.0  •  web-01                                  root  •  14 accounts
╭─ Accounts ────────────────────╮ ╭─ deploy ──────────────────────────────────────╮
│ ✓ root                0       │ │ IDENTITY                                      │
│ ✓ deploy              1001    │ │ user            deploy                        │
│ ✗ contractor          1002    │ │ uid / gid       1001 / 1001                   │
│ ! expired-svc         1003    │ │ home            /home/deploy                  │
│                               │ │ shell           /bin/bash                     │
│                               │ │ groups          docker www-data               │
│                               │ │ privileged      no                            │
│                               │ │                                               │
│                               │ │ PASSWORD                                      │
│                               │ │ state           ACTIVE                        │
│                               │ │ expires         never                         │
│                               │ │                                               │
│                               │ │ SSH                                           │
│                               │ │ password auth   no                            │
│                               │ │ authorized keys 2                             │
╰───────────────────────────────╯ ╰───────────────────────────────────────────────╯
 14 account(s) loaded. Press ? for help.
 a·add  e·edit  d·del  p·passwd  L·lock  g·groups  k·keys  s·ssh  x·disable  q·quit
```

---

## Install

```bash
sudo ./install.sh                 # installs to /usr/local
sudo ./install.sh --prefix /opt   # or elsewhere
sudo ./install.sh --uninstall
sudo ./install.sh --dry-run       # show what it would do
```

The installer runs the installed binary before declaring success, and exits 70
if it does not work. On success it prints:

```
Verifying the installation...
  ok   /usr/local/bin/users-pro -> users-pro 2.0.0
  ok   library loaded from /usr/local/lib/users-pro
  ok   /usr/local/bin/users-pro-tui is executable

Installed and verified. The command is:  users-pro   (note the 's')
```

**The command is `users-pro`** — plural. `user-pro` is not it.

Or skip installation entirely — build a single self-contained file and copy it
to the box:

```bash
./build.sh
scp dist/users-pro dist/users-pro-tui root@server:/usr/local/bin/
```

---

## The interface

```bash
sudo users-pro tui        # or: users-pro-tui
users-pro-tui             # without root: read-only browsing
```

| Key | Action |
|-----|--------|
| `↑ ↓` / `j k` | Move selection |
| `PgUp` `PgDn` `Home` `End` | Page / jump |
| `[` `]` | Scroll the detail pane |
| `/` | Live filter (username and full name); `Esc` clears |
| `Tab` | Show/hide system accounts |
| `a` | Create an account |
| `e` | Edit the selected account |
| `d` | Delete the selected account |
| `p` | Set a password (type or generate) |
| `L` | Lock / unlock the password |
| `g` | Manage supplementary groups |
| `x` | Disable / enable (lock + expire + nologin) |
| `k` | Manage `authorized_keys` |
| `s` | Toggle per-user SSH `PasswordAuthentication` |
| `i` | Full text report |
| `l` | Recent audit log entries |
| `D` | Toggle dry-run mode |
| `r` | Reload |
| `?` | Help |
| `q` | Quit |

In forms: `Tab`/`↑↓` move between fields, `Enter` edits a text field,
`←→`/`Space` cycle a toggle, **`Ctrl-S` or `F2` saves**, `Esc` cancels.

**Destructive actions require typing the account name.** Deleting an account or
wiping its keys will not proceed on a stray keypress. That confirmation is the
guard — so when an account needs `force` (system account, privileged group,
running processes), the delete form says so and pre-arms the toggle rather than
rejecting you first and making you find it.

Press `D` to arm dry-run: the header shows a `DRY-RUN` badge and every action
reports what it *would* do without touching the system. Useful for rehearsing a
change on production before committing to it.

---

## CLI

Everything the interface does is scriptable.

```bash
users-pro list                                    # no root needed
users-pro list --all --json | jq '.[] | select(.state=="LOCKED")'
users-pro info -u deploy

users-pro add -u deploy --groups docker --generate-password
users-pro add -u svc --shell /usr/sbin/nologin --no-password
printf '%s\n' "$PW" | users-pro add -u ci --password-stdin -y

users-pro edit -u deploy --max-days 90 --add-groups www-data
users-pro edit -u deploy --ssh-password-auth no
users-pro disable -u contractor
users-pro enable  -u contractor

users-pro keys -u deploy --list
users-pro keys -u deploy --add-file ~/team-keys.pub
users-pro keys -u deploy --remove "laptop-2023"

users-pro --dry-run delete -u olduser --backup-home /var/backups/olduser.tar.gz
users-pro audit -l 100
```

Global flags on every command: `--dry-run` `--yes` `--quiet` `--verbose`
`--json` `--no-color` `--audit-log PATH` `--help`.

### Exit codes

Distinct per failure class, so CI can branch on them.

| Code | Meaning |
|------|---------|
| 0 | Success |
| 64 | Usage error |
| 65 | Invalid data |
| 67 | No such user |
| 69 | Missing dependency |
| 70 | Internal failure |
| 77 | Permission denied |
| 78 | Configuration error |
| 79 | Conflict (already exists, processes running) |

---

## What it manages

- **Accounts** — create, delete, edit, disable/enable, with home directory
  handling, explicit UID/home, and GECOS.
- **Passwords** — set, generate (20 chars from `/dev/urandom`), strength
  warnings, lock/unlock, aging (`min`/`max`/`warn`/`inactive`), force change at
  next login.
- **Groups** — add, remove, replace, clear. Privileged groups (`sudo`, `admin`,
  `wheel`, `root`, `adm`, `sudoers`) require `--allow-privileged`.
- **SSH** — per-user `PasswordAuthentication` via drop-in or a managed `Match`
  block, validated with `sshd -t` and rolled back if rejected;
  `authorized_keys` add/import/remove/clear with `ssh-keygen` validation.
- **sudo** — an optional managed `NOPASSWD` drop-in in `/etc/sudoers.d`,
  validated with `visudo -c` before installation.
- **Backups** — home directory archives, mode 0600, compression inferred from
  the extension.
- **Audit** — every mutation to `/var/log/users-pro.log` (0640) and syslog
  `authpriv.notice`, tagged with the invoking `SUDO_USER`.

---

## Safety

- `root` and other system accounts are protected outright; system accounts
  (uid < 1000) need `--force`.
- Home directory removal is refused for any path outside the permitted areas —
  `/`, `/etc`, `/usr`, `/var` and friends are rejected after `realpath`
  resolution, so `/home/x/../../etc` does not slip through.
- An advisory `flock` prevents concurrent runs from interleaving `/etc/passwd`
  and `sshd_config` writes.
- Passwords are piped to `chpasswd` through the `printf` **builtin**, so they
  never appear in `/proc/*/cmdline`, and are cleared from memory on exit.
- SSH configuration changes are validated with `sshd -t` and rolled back from a
  backup if rejected. You cannot lock yourself out through a syntax error.

---

## Layout

```
bin/users-pro          CLI entry point, table-driven option parser
bin/users-pro-tui      TUI entry point
lib/core.sh            strict mode, logging, audit, validation, locking
lib/account.sh         account lifecycle operations
lib/ssh.sh             sshd_config and authorized_keys
lib/query.sh           read-only introspection, JSON
lib/tui/term.sh        terminal control, palette, frame buffer
lib/tui/input.sh       escape-sequence key decoding
lib/tui/widgets.sh     modals, confirmations, editors, pickers, forms
lib/tui/app.sh         panes, actions, main loop
tests/run-tests.sh     unit + integration
tests/tui-tests.sh     pty-driven interface tests
tests/tui-drive.py     pty driver and terminal emulator
build.sh               flatten to single-file bundles
install.sh             install / uninstall
```

The library knows nothing about `argv` and never prints usage; the entry points
never touch the system directly. That separation is what made the TUI possible
without duplicating any logic.

**Rendering** is pull-based: state changes set a dirty flag and the loop paints
one frame with a single `write`, so the screen never tears. Expensive lookups
(`sshd -T`, `chage`, `du`) are deferred to idle ticks, so holding an arrow key
stays instant no matter how many accounts exist.

---

## Tests

```bash
sudo tests/function-tests.sh     # 172 tests: every library function, by name
sudo tests/run-tests.sh          # 91 tests: unit + full lifecycle
sudo tests/run-tests.sh --unit-only
sudo tests/tui-tests.sh          # 26 tests: drives a real pty
sudo tests/tui-survival.py       # 34 tests: every action, then keeps pressing keys
shellcheck -s bash -x -e SC1091 bin/* lib/*.sh lib/tui/*.sh
```

`function-tests.sh` exists because a coverage audit found 150 of 195 functions
had never been called by name in a test. Integration tests exercise the success
path; they do not tell you that each function behaves correctly on its own. The
first run of it found a bug that made every error guard in the codebase inert.

No Bats required — a tool that can only be verified after `npm install -g bats`
does not get verified on a server. The harness runs anywhere bash runs.

Integration tests create accounts under a reserved `upt-`/`tuitest-` prefix and
clean up after themselves. They skip automatically without root.

The TUI tests drive the real binary through a pseudoterminal. `tui-tests.sh`
asserts on the rendered frame; `tui-survival.py` goes further and keeps pressing
keys *after* each dialog is dismissed, then checks the process is still alive.

That second suite exists because asserting on a frame is not enough. A refusal
modal can render perfectly and the session can still die the moment you dismiss
it — which is exactly what shipped in 2.1.0. Both suites are validated against
the known-bad build to confirm they actually go red.

---

## Requirements

- bash 4.4+ (5.x recommended)
- shadow-utils: `useradd` `userdel` `usermod` `chage` `passwd` `gpasswd` `chpasswd`
- coreutils, `getent`, `awk`, `grep`, `sed`
- Optional: `openssh-server`, `flock`, `logger`, `visudo`, `pgrep`/`pkill`,
  `ssh-keygen`, `python3` (tests only)

Tuned for Ubuntu 26.04 LTS; runs on any systemd Linux with shadow-utils.

---

## Author

`YogSotho`
