#!/usr/bin/env python3

"""Codex の composer が prompt text を受け取れても、直後の Enter を無視する状態を模す。"""

import os
import select
import sys
import termios
import time
import tty


def main() -> None:
    output_file = sys.argv[1]
    fd = sys.stdin.fileno()
    original = termios.tcgetattr(fd)
    buffer = bytearray()

    try:
        tty.setraw(fd)
        deadline = time.monotonic() + 0.5
        while time.monotonic() < deadline:
            readable, _, _ = select.select([fd], [], [], 0.05)
            if readable:
                buffer.extend(byte for byte in os.read(fd, 1024) if byte not in (10, 13))

        while True:
            byte = os.read(fd, 1)
            if byte in (b"\r", b"\n"):
                with open(output_file, "wb") as output:
                    output.write(buffer)
                return
            buffer.extend(byte)
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, original)


if __name__ == "__main__":
    main()
