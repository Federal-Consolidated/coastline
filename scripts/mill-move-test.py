#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyserial>=3.5"]
# ///
"""First motion test on a real machine: home, then short jogs on Y and X and back,
or home and then run a small G-code file.

Sends only `?`, `$$`, `$H` and the jogs below (G21, relative, F1000, spindle never on).
With --gcode, the file is checked before the port opens: only G0 G1 G4 G21 G53 G90 G91 M5
with X Y Z F P words, absolute moves only with G53, and every position inside the travel.
Refuses to start unless the mill answers, is in Alarm or Idle, no limit switch is tripped,
and soft limits and homing are on. Stops at the first error. Ctrl-C (or an error once
moving) sends feed hold, jog cancel (0x85) and soft reset (0x18).

Usage: scripts/mill-move-test.py --yes-move [--home-only | --gcode FILE] [/dev/cu.usbmodemXXXX]
"""
import argparse
import re
import sys
import time

import serial

BAUD = 115200
OK = re.compile(r"^(ok|[0-3]k|K[0-9A-F])$")
# After $H the machine sits at X -86.0, Y -0.5, Z -0.5 (X homes to its negative end), so X jogs + first.
JOGS = ("$J=G91 G21 Y-20 F1000", "$J=G91 G21 Y20 F1000", "$J=G91 G21 X10 F1000", "$J=G91 G21 X-10 F1000")
HOME = (-86.0, -0.5, -0.5)  # machine position after $H
ENVELOPE = ((-86.0, -0.5), (-241.0, -0.5), (-78.0, -0.5))  # $130-$132 travel, 0.5 mm in from each end
ALLOWED = {"G0", "G1", "G4", "G21", "G53", "G90", "G91", "M5"}
START = time.monotonic()


def log(direction, text):
    print(f"{time.monotonic() - START:7.3f} {direction} {text}", flush=True)


class Stop(Exception):
    pass


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
        end = time.monotonic() + limit
        while time.monotonic() < end and self.read_line(min(end, time.monotonic() + quiet)) is not None:
            pass

    def status(self, timeout=1.0):
        self.port.write(b"?")
        end = time.monotonic() + timeout
        while (line := self.read_line(end)) is not None:
            if line.startswith("<"):
                return parse_status(line)
        return None

    def command(self, line, timeout):
        log("->", line)
        self.port.write(line.encode() + b"\n")
        lines, end = [], time.monotonic() + timeout
        while (reply := self.read_line(end)) is not None:
            if OK.match(reply):
                return lines
            if reply.startswith(("error", "ALARM")):
                raise Stop(f"{line} failed: {reply}")
            lines.append(reply)
        raise Stop(f"{line}: no reply in {timeout:.0f} s")

    def wait_idle(self, timeout):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            s = self.status()
            if s and s["state"] == "Idle":
                return s
            if s and s["state"].startswith("Alarm"):
                raise Stop(f"alarm while moving: {s['raw']}")
            time.sleep(0.1)
        raise Stop(f"not Idle after {timeout:.0f} s")

    def abort(self):
        log("->", "! feed hold, 0x85 jog cancel, 0x18 soft reset")
        self.port.write(b"!")
        time.sleep(0.3)
        self.port.write(b"\x85")
        time.sleep(0.05)
        self.port.write(b"\x18")


def load_gcode(path):
    """Cleans the file and checks every line before anything is sent."""
    lines, pos, relative = [], list(HOME), False
    for number, raw in enumerate(open(path), 1):
        line = re.sub(r"\(.*?\)|;.*", "", raw).replace(" ", "").strip().upper()
        if not line:
            continue
        words = re.findall(r"([A-Z])(-?\d*\.?\d+)", line)
        if "".join(l + v for l, v in words) != line or {l for l, _ in words} - set("GMXYZFP"):
            raise Stop(f"line {number}: not allowed: {raw.strip()!r}")
        codes = {f"{l}{float(v):g}" for l, v in words if l in "GM"}
        if codes - ALLOWED:
            raise Stop(f"line {number}: {sorted(codes - ALLOWED)} not allowed")
        relative = (relative or "G91" in codes) and "G90" not in codes
        axes = {l: float(v) for l, v in words if l in "XYZ"}
        if axes and relative == ("G53" in codes):
            raise Stop(f"line {number}: absolute moves must use G53, relative moves must not")
        for i, axis in enumerate("XYZ"):
            if axis in axes:
                pos[i] = pos[i] + axes[axis] if relative else axes[axis]
                low, high = ENVELOPE[i]
                if not low <= round(pos[i], 4) <= high:
                    raise Stop(f"line {number}: {axis} would go to {pos[i]:.3f}, outside {low}..{high}")
        lines.append(line)
    return lines


def parse_status(raw):
    fields = raw[1:-1].split("|")
    pins = next((f for f in fields[3:5] if len(f) == 4 and not f.startswith("L")), "????")
    position = next((f[2:] for f in fields if f.startswith("M:")), "")
    return {"raw": raw, "state": fields[0], "pins": pins, "mpos": position}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("port", nargs="?", default="/dev/cu.usbmodem1101")
    parser.add_argument("--yes-move", action="store_true")
    parser.add_argument("--home-only", action="store_true")
    parser.add_argument("--gcode", metavar="FILE")
    options = parser.parse_args()
    if not options.yes_move:
        sys.exit("this script moves the machine: run it with --yes-move")
    try:
        program = load_gcode(options.gcode) if options.gcode else None
    except Stop as e:
        sys.exit(f"refused before connecting: {e}")
    if program:
        log("--", f"{options.gcode}: {len(program)} lines checked")
    mill = Mill(options.port)
    moving = False
    try:
        log("--", "waiting for the banner")
        end = time.monotonic() + 6  # the board restarts when the port opens (~2.3 s)
        while (line := mill.read_line(end)) is not None and not re.match(r"^Grbl \d+\.\d+", line):
            pass
        mill.drain()
        s = mill.status(timeout=1.5)
        if s is None:
            raise Stop("no reply to '?': release the E-stop (turn the red knob clockwise)")
        log("--", f"state {s['state']}, pins {s['pins']}, M {s['mpos']}")
        if not s["state"].startswith(("Alarm", "Idle")):
            raise Stop(f"state is {s['state']}, expected Alarm or Idle")
        if any(c in s["pins"][1:] for c in "XYZ"):
            raise Stop(f"a limit switch is tripped ({s['pins']})")
        settings = dict(re.findall(r"^\$(\d+)=(\S+)", "\n".join(mill.command("$$", 3)), re.M))
        if settings.get("20") != "1" or settings.get("22") != "1":
            raise Stop(f"soft limits ($20={settings.get('20')}) and homing ($22={settings.get('22')}) must be on")

        log("--", "HOMING: the mill now moves to its home switches")
        moving = True
        mill.command("$H", timeout=60)  # the firmware is silent until homing ends
        s = mill.wait_idle(5)
        log("--", f"homed: M {s['mpos']}, pins {s['pins']}")
        if any(abs(float(v) - h) > 0.01 for v, h in zip(s["mpos"].split(","), HOME)):
            raise Stop(f"home position {s['mpos']} is not {HOME}: the file check does not apply")
        if program:
            for line in program:
                mill.command(line, timeout=30)  # ok comes when the planner has room
            s = mill.wait_idle(60)
            log("--", f"program done at M {s['mpos']}")
        elif not options.home_only:
            for jog in JOGS:
                mill.command(jog, timeout=3)
                s = mill.wait_idle(15)
                log("--", f"at M {s['mpos']}")
        log("--", "test complete")
        return 0
    except KeyboardInterrupt:
        if moving:
            mill.abort()
        log("--", "stopped by Ctrl-C")
        return 130
    except Stop as e:
        if moving:
            mill.abort()
        log("--", f"STOPPED: {e}")
        return 1
    finally:
        mill.drain(quiet=0.3, limit=1.0)
        mill.port.close()


if __name__ == "__main__":
    sys.exit(main())
