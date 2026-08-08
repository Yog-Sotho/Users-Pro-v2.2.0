#!/usr/bin/env python3
"""Survival matrix — drive every TUI action to completion and assert the
session is still alive and still rendering afterwards.

This exists because the earlier TUI tests only asserted on a *rendered frame*.
They confirmed the error modal appeared and stopped there. Dismissing that modal
exited the whole interface with code 77, and no test noticed, because none of
them ever pressed a key after a modal.

Every case here therefore does three things:
  1. drive the action to its end state
  2. dismiss whatever dialog is showing
  3. keep navigating, then assert the process is alive and painting

Usage: sudo tests/tui-survival.py
"""
import fcntl
import os
import pty
import re
import select
import signal
import struct
import subprocess
import sys
import termios
import time

TUI = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bin", "users-pro-tui")
ANSI = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z]")

PASS = FAIL = 0
GRN, RED, DIM, YEL, RST = "\033[32m", "\033[31m", "\033[2m", "\033[33m", "\033[0m"
if not sys.stdout.isatty():
    GRN = RED = DIM = YEL = RST = ""


def ok(msg):
    global PASS
    PASS += 1
    print(f"  {GRN}PASS{RST} {msg}")


def bad(msg, detail=""):
    global FAIL
    FAIL += 1
    print(f"  {RED}FAIL{RST} {msg}")
    if detail:
        print(f"       {DIM}{detail}{RST}")


class Session:
    def __init__(self, cols=110, rows=30, argv=()):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.environ.update(TERM="xterm-256color", LANG="C.UTF-8")
            os.execv("/bin/bash", ["bash", os.path.abspath(TUI)] + list(argv))
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        self.buf = b""
        self._code = None
        self.pump(1.6)

    def pump(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            if select.select([self.fd], [], [], 0.05)[0]:
                try:
                    chunk = os.read(self.fd, 1 << 16)
                except OSError:
                    return
                if not chunk:
                    return
                self.buf += chunk

    def send(self, *keys, settle=0.5):
        for k in keys:
            os.write(self.fd, k if isinstance(k, bytes) else k.encode())
            self.pump(settle)

    def text(self):
        return ANSI.sub("", self.buf.decode("utf-8", "replace"))

    def clear(self):
        self.buf = b""

    def alive(self):
        # waitpid raises ChildProcessError once the child has been reaped, and
        # an earlier version of this helper swallowed that as "still alive" —
        # which is why the negative control appeared to pass against a build
        # that provably died. Reap once and cache.
        if self._code is not None:
            return False
        try:
            st = os.waitpid(self.pid, os.WNOHANG)
        except ChildProcessError:
            self._code = -1
            return False
        if st == (0, 0):
            return True
        self._code = os.waitstatus_to_exitcode(st[1])
        return False

    def exit_code(self):
        self.alive()
        return self._code

    def close(self):
        try:
            os.kill(self.pid, signal.SIGKILL)
            os.waitpid(self.pid, 0)
        except Exception:
            pass
        try:
            os.close(self.fd)
        except Exception:
            pass


def survives(name, keys, setup=None, teardown=None, cols=110, rows=30):
    """Drive keys, dismiss any dialog, keep navigating, assert still alive."""
    if setup:
        subprocess.run(setup, shell=True, capture_output=True)
    s = Session(cols, rows)
    try:
        s.send(*keys)
        s.clear()
        # The original bug killed the session on the keystroke AFTER the modal
        # was dismissed, not on the dismissal itself. Press several keys and
        # check liveness after each one.
        for i, k in enumerate((b" ", b"\x1b", b"j", b"k", b"j", b"\x1b")):
            s.send(k, settle=0.45)
            if not s.alive():
                bad(name, f"session exited with code {s.exit_code()} "
                          f"on post-dismissal keystroke {i + 1} ({k!r})")
                return
        painted = "Accounts" in s.text() or "accounts" in s.text()
        if painted:
            ok(name)
        else:
            bad(name, "session alive but stopped painting")
    finally:
        s.close()
        if teardown:
            subprocess.run(teardown, shell=True, capture_output=True)


def typed(word):
    return [c.encode() for c in word]


print(f"\n{DIM}── refusal paths (the class of bug that shipped){RST}")

# THE REGRESSION. Deleting a privileged account without force: the guard fires,
# the modal renders, and dismissing it used to exit the interface with 77.
survives(
    "privileged delete refused -> session survives dismissal",
    [b"\x1b[B", b"\x1b[B", b"d", b"\x13"] + typed("survpriv") + [b"\r"],
    setup="userdel --remove survpriv 2>/dev/null; groupdel survpriv 2>/dev/null; "
          "useradd --create-home --user-group survpriv && usermod -aG sudo survpriv",
    teardown="userdel --remove survpriv 2>/dev/null; groupdel survpriv 2>/dev/null",
)

# Editing a system account without force is refused the same way.
survives(
    "system-account edit refused -> session survives",
    [b"e", b"\x13"],
)

# Creating an account that already exists.
survives(
    "duplicate create refused -> session survives",
    [b"a", b"\r"] + typed("root") + [b"\r", b"\x13"],
)

# An invalid username must be rejected without taking the session with it.
survives(
    "invalid username refused -> session survives",
    [b"a", b"\r"] + typed("Bad Name!") + [b"\r", b"\x13"],
)

# A group that does not exist.
survives(
    "unknown group refused -> session survives",
    [b"\x1b[B", b"g", b"\t", b"\t", b"\r"] + typed("no-such-group-xyz") + [b"\r", b"\x13"],
)

# Assigning a privileged group without the allow toggle.
survives(
    "privileged group refused -> session survives",
    [b"\x1b[B", b"g", b"\t", b"\t", b"\r"] + typed("sudo") + [b"\r", b"\x13"],
)

print(f"\n{DIM}── every action opened and dismissed{RST}")

for key, label in [
    (b"a", "create form"),
    (b"e", "edit form"),
    (b"d", "delete form"),
    (b"p", "password form"),
    (b"g", "groups form"),
    (b"K", "keys menu"),
    (b"i", "full report"),
    (b"l", "audit log"),
    (b"?", "help"),
    (b"s", "ssh toggle"),
    (b"x", "disable toggle"),
    (b"L", "lock toggle"),
    (b"D", "dry-run toggle"),
    (b"r", "reload"),
]:
    survives(f"{label} opens and dismisses cleanly", [b"\x1b[B", key])

print(f"\n{DIM}── cancel paths (Esc out of every dialog){RST}")

for key, label in [
    (b"a", "create"), (b"e", "edit"), (b"d", "delete"),
    (b"p", "password"), (b"g", "groups"), (b"K", "keys"),
]:
    survives(f"Esc out of {label} leaves the session running",
             [b"\x1b[B", key, b"\x1b"])

print(f"\n{DIM}── stress{RST}")

# Hammer every bound key in sequence; nothing may end the session.
survives(
    "every bound key pressed in sequence",
    [bytes([c]) for c in b"aedpgKilsxLDr?/"] + [b"\x1b"] * 6 + [b"j", b"k"],
)

# Rapid navigation while detail lookups are deferred.
survives("rapid navigation", [b"j"] * 12 + [b"k"] * 12 + [b"\t", b"\t"])

# Filter mode with no matches, then recover.
survives("filter with no matches recovers",
         [b"/"] + typed("zzzznomatch") + [b"\x1b", b"j"])

# Cramped terminal.
survives("actions in a cramped 60x14 terminal", [b"a", b"\x1b", b"d", b"\x1b"], cols=60, rows=14)


print(f"\n{DIM}── delete usability (five failed attempts shipped before this){RST}")


def deletes(name, username, keys, setup):
    subprocess.run(f"userdel --remove {username} 2>/dev/null; groupdel {username} 2>/dev/null",
                   shell=True, capture_output=True)
    subprocess.run(setup, shell=True, capture_output=True)
    s = Session(100, 26)
    try:
        s.send(*keys, settle=0.5)
        s.pump(1.0)
    finally:
        s.close()
    gone = subprocess.run(f"getent passwd {username}", shell=True,
                          capture_output=True).returncode != 0
    subprocess.run(f"userdel --remove {username} 2>/dev/null; groupdel {username} 2>/dev/null",
                   shell=True, capture_output=True)
    ok(name) if gone else bad(name, "account still exists after the delete flow")


def seq(user):
    return ([b"/"] + typed(user) + [b"\r", b"d", b"\x13"] + typed(user) + [b"\r"])


# A privileged account must delete on the FIRST pass of the ordinary flow. The
# override is pre-armed and stated in the form; requiring the user to fail once,
# read an error, hunt for a toggle and retry is not a safety control, it is a
# defect. The typed-name confirmation is the real guard.
deletes("privileged account deletes on the first attempt", "survdel1", seq("survdel1"),
        "useradd --create-home --user-group survdel1 && usermod -aG sudo survdel1")

deletes("ordinary account deletes on the first attempt", "survdel2", seq("survdel2"),
        "useradd --create-home --user-group survdel2")

# The form must name the account and the reason; blank informational rows were
# what made the override undiscoverable.
s_ = Session(100, 26)
try:
    subprocess.run("userdel --remove survdel3 2>/dev/null; groupdel survdel3 2>/dev/null; "
                   "useradd --create-home --user-group survdel3 && usermod -aG sudo survdel3",
                   shell=True, capture_output=True)
    s_.send(*([b"/"] + typed("survdel3") + [b"\r", b"d"]), settle=0.5)
    txt = s_.text()
    if "survdel3" in txt and "privileged group" in txt:
        ok("delete form names the account and states why force is needed")
    else:
        bad("delete form content", "form did not state the account or the reason")
finally:
    s_.close()
    subprocess.run("userdel --remove survdel3 2>/dev/null; groupdel survdel3 2>/dev/null",
                   shell=True, capture_output=True)

# root must remain undeletable no matter what.
s_ = Session(100, 26)
try:
    s_.send(*([b"d", b"\x13"] + typed("root") + [b"\r", b" "]), settle=0.5)
finally:
    s_.close()
still = subprocess.run("getent passwd root", shell=True, capture_output=True).returncode == 0
ok("root remains undeletable") if still else bad("root protection", "root was removed")

print(f"\n{DIM}{'─' * 56}{RST}")
print(f"{GRN}PASS {PASS}{RST}   {RED}FAIL {FAIL}{RST}")
sys.exit(1 if FAIL else 0)
