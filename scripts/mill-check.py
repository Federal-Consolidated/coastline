#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyserial>=3.5"]
# ///
"""Read-only connection check for a GRBL desktop mill.

Opens the port, waits for the GRBL banner, then sends only query commands:
`?`, `$I`, `$$`, `$#`, `$G` and `$N`. None of them moves the machine or writes
a setting. Every line in and out is printed with a timestamp.

Opening the port restarts the Arduino board (DTR). That is normal and causes no motion.

Usage: scripts/mill-check.py [/dev/cu.usbmodemXXXX]
"""
import re
import sys
import time

import serial
from serial.tools import list_ports

BAUD = 115200
KNOWN_IDS = {(0x2341, 0x0043), (0x1A86, 0x7523)}  # Arduino Uno, CH340 (as MillCore's PortFinder)
QUERIES = ("$I", "$$", "$#", "$G", "$N")  # the only line commands this script may send
OK = re.compile(r"^(ok|[0-3]k|K[0-9A-F])$")  # some GRBL builds also answer 0k-3k (M105 mode)
START = time.monotonic()


def log(direction, text):
    print(f"{time.monotonic() - START:7.3f} {direction} {text}", flush=True)


def find_port():
    for p in list_ports.comports():
        if (p.vid, p.pid) in KNOWN_IDS and p.device.startswith("/dev/cu."):
            log("--", f"found {p.device} {p.vid:04x}:{p.pid:04x} {p.manufacturer} serial={p.serial_number}")
            return p.device
    sys.exit("no mill found (looked for USB IDs 2341:0043 and 1a86:7523)")


class Mill:
    def __init__(self, port):
        self.port = serial.Serial(port, BAUD, timeout=0.05)
        self.pending = b""

    def read_line(self, deadline):
        while time.monotonic() < deadline:
            if b"\n" in self.pending:
                line, self.pending = self.pending.split(b"\n", 1)
                text = line.decode("ascii", "replace").strip()
                if text:
                    log("<-", text)
                    return text
                continue
            self.pending += self.port.read(256)
        return None

    def drain(self, quiet=0.5, limit=3.0):
        """Reads lines until the port is quiet for `quiet` seconds."""
        lines, end = [], time.monotonic() + limit
        while time.monotonic() < end:
            line = self.read_line(min(end, time.monotonic() + quiet))
            if line is None:
                break
            lines.append(line)
        return lines

    def status(self, timeout=1.0):
        log("->", "?")
        self.port.write(b"?")
        end = time.monotonic() + timeout
        while (line := self.read_line(end)) is not None:
            if line.startswith("<"):
                return line
        return None

    def query(self, command, timeout=3.0):
        assert command in QUERIES, f"refusing to send {command!r}: not a read-only query"
        log("->", command)
        self.port.write(command.encode() + b"\n")
        lines, end = [], time.monotonic() + timeout
        while (line := self.read_line(end)) is not None:
            if OK.match(line) or line.startswith(("error", "ALARM")):
                return lines, line
            lines.append(line)
        return lines, None


def main():
    port = sys.argv[1] if len(sys.argv) > 1 else find_port()
    mill = Mill(port)
    log("--", f"opened {port} at {BAUD} 8N1")

    banner, end = None, time.monotonic() + 6
    while banner is None and (line := mill.read_line(end)) is not None:
        if re.match(r"^Grbl \d+\.\d+", line):
            banner = line
    if banner is None:
        log("--", "no 'Grbl x.y' banner in 6 s")
    mill.drain()

    first = mill.status(timeout=1.5)
    if first is None:
        log("--", "no reply to '?': the E-stop is probably pressed, or the board is not GRBL")
        return 1

    replies = {}
    for command in QUERIES:
        replies[command] = mill.query(command)
        mill.drain(quiet=0.2, limit=1.0)

    statuses = []
    for _ in range(12):
        if (s := mill.status()) is not None:
            statuses.append(s)
        time.sleep(0.25)
    mill.port.close()

    print("\n==== summary ====")
    print(f"port        {port}")
    print(f"banner      {banner}")
    print(f"first ?     {first}")
    for command, (lines, final) in replies.items():
        print(f"{command:<11} {final}  ({len(lines)} lines)")
    info = " ".join(replies["$I"][0])
    print(f"$I          {info}")
    # The machine's own tag in $I (e.g. "XY:3A" after grbl:1.1g), not counting the board fields.
    tags = [t for t in re.findall(r"\b([A-Z]{2,3}):(\w+)", info) if t[0] not in ("PCB", "VFD", "YMD")]
    print(f"family tag  {':'.join(tags[0]) if tags else 'none'}")
    short = all(re.search(r"\|M:|\|W:", s) for s in [first, *statuses])
    standard = any(re.search(r"MPos:|WPos:", s) for s in [first, *statuses])
    print(f"status fmt  {'short (M:/W:)' if short else 'standard GRBL (MPos/WPos)' if standard else 'unknown'}")
    print(f"W: seen     {sum('|W:' in s for s in statuses)} of {len(statuses)} later reports")
    settings = dict(re.findall(r"^\$(\d+)=(\S+)", "\n".join(replies["$$"][0]), re.M))
    for key, name in [("13", "report inches"), ("20", "soft limits"), ("21", "hard limits"), ("22", "homing"),
                      ("23", "homing dir mask"), ("110", "max rate X"), ("111", "max rate Y"), ("112", "max rate Z"),
                      ("130", "travel X"), ("131", "travel Y"), ("132", "travel Z")]:
        print(f"${key:<10} {settings.get(key, '-'):>10}  {name}")
    print(f"startup     {replies['$N'][0]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
