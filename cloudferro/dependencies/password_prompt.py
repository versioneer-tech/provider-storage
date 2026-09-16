#!/usr/bin/env python3
# Copyright 2026, EOX (https://eox.at) and Versioneer (https://versioneer.at)
# SPDX-License-Identifier: Apache-2.0

"""Give OpenStack's password prompt a private terminal without exposing the password."""

import os
from pathlib import Path
import pty
import selectors
import subprocess
import sys
import termios
import time


def main() -> int:
    if len(sys.argv) < 3:
        return 2

    password = Path(sys.argv[1]).read_text(encoding="utf-8")
    if not password or "\n" in password or "\r" in password:
        print("Invalid password input for OpenStack CLI.", file=sys.stderr)
        return 2

    master, slave = pty.openpty()
    settings = termios.tcgetattr(slave)
    settings[3] &= ~(termios.ECHO | termios.ECHONL)
    termios.tcsetattr(slave, termios.TCSANOW, settings)

    try:
        process = subprocess.Popen(
            sys.argv[2:],
            stdin=slave,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
    finally:
        os.close(slave)

    output = bytearray()
    error = bytearray()
    sent = 0
    deadline = time.monotonic() + 120
    with selectors.DefaultSelector() as selector:
        selector.register(process.stdout, selectors.EVENT_READ, output)
        selector.register(process.stderr, selectors.EVENT_READ, error)
        while selector.get_map():
            ready = selector.select(max(0, deadline - time.monotonic()))
            if not ready:
                process.kill()
                error.extend(b"\nPassword prompt timed out.\n")
                break
            for key, _ in ready:
                chunk = os.read(key.fileobj.fileno(), 4096)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                key.data.extend(chunk)
                if key.data is error:
                    while sent < min(2, error.count(b"User Password:")):
                        os.write(master, (password + "\n").encode("utf-8"))
                        sent += 1

    os.close(master)
    process.wait()
    os.write(sys.stdout.fileno(), output)
    os.write(sys.stderr.fileno(), error)
    return process.returncode


if __name__ == "__main__":
    sys.exit(main())
