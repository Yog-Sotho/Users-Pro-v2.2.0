#!/usr/bin/env python3
"""Drive users-pro-tui in a pty and render the resulting screen as text.

Usage: tui-drive.py '["j","?"]' [cols] [rows]

This exists so the interface can be regression-tested without a human staring
at it: it replays a key sequence, interprets the cursor-positioning escapes the
same way a terminal would, and prints the final frame.
"""
import os
import pty
import re
import select
import signal
import struct
import sys
import termios
import fcntl
import time

TUI = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bin", "users-pro-tui")


def drive(keys, cols=110, rows=32, settle=1.2, per_key=0.55, argv=()):
    pid, fd = pty.fork()
    if pid == 0:
        os.environ.update(
            TERM="xterm-256color", COLORTERM="truecolor", LANG="C.UTF-8",
            COLUMNS=str(cols), LINES=str(rows),
        )
        os.execv("/bin/bash", ["bash", os.path.abspath(TUI)] + list(argv))

    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    buf = b""

    def pump(duration):
        nonlocal buf
        end = time.time() + duration
        while time.time() < end:
            if select.select([fd], [], [], 0.05)[0]:
                try:
                    chunk = os.read(fd, 1 << 16)
                except OSError:
                    return
                if not chunk:
                    return
                buf += chunk

    pump(settle)
    for key in keys:
        os.write(fd, key.encode() if isinstance(key, str) else key)
        pump(per_key)
    pump(0.6)

    try:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
    except Exception:
        pass
    try:
        os.close(fd)
    except Exception:
        pass
    return buf.decode("utf-8", "replace")


CSI = re.compile(r"\x1b\[([0-9;?]*)([a-zA-Z])")
PRIV = re.compile(r"\x1b\[\?[0-9]+[hl]")


def render(text, cols=110, rows=32):
    """Replay cursor addressing into a character grid, ignoring colour."""
    grid = [[" "] * cols for _ in range(rows)]
    row = col = 0
    i = 0
    while i < len(text):
        ch = text[i]
        if ch == "\x1b":
            m = PRIV.match(text, i)
            if m:
                i = m.end()
                continue
            m = CSI.match(text, i)
            if m:
                params, cmd = m.group(1), m.group(2)
                if cmd == "H":
                    parts = [p for p in params.split(";") if p]
                    row = int(parts[0]) - 1 if len(parts) > 0 else 0
                    col = int(parts[1]) - 1 if len(parts) > 1 else 0
                elif cmd == "J" and params == "2":
                    grid = [[" "] * cols for _ in range(rows)]
                i = m.end()
                continue
            i += 1
            continue
        if ch == "\n":
            row += 1
            col = 0
        elif ch == "\r":
            col = 0
        else:
            if 0 <= row < rows and 0 <= col < cols:
                grid[row][col] = ch
            col += 1
        i += 1
    return "\n".join("".join(r).rstrip() for r in grid)


if __name__ == "__main__":
    argv = []
    args = sys.argv[1:]
    if "--" in args:
        i = args.index("--")
        argv = args[i + 1:]
        args = args[:i]
    keys = eval(args[0]) if len(args) > 0 else ["q"]
    cols = int(args[1]) if len(args) > 1 else 110
    rows = int(args[2]) if len(args) > 2 else 32
    print(render(drive(keys, cols, rows, argv=argv), cols, rows))
