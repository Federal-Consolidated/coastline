#!/usr/bin/env python3
"""Writes G-code that plays Korobeiniki (the Tetris theme) with the machine's Y stepper.

A stepper sings at its step rate: f = F / 60 * steps_per_mm, so each note is a G1 move at
F = f * 60 / steps_per_mm, and its length in mm sets how long it lasts. The direction
changes on every note, so the gantry stays within about 1.3 mm of the start point.
Spindle off, Y only.

Usage: scripts/make-song.py > song.nc
"""
STEPS_PER_MM = 400.0  # $101 on the machine
BPM = 120
START_Y = -30.0  # machine Y, well inside the 241.5 mm travel
NOTES = {"A4": 440.00, "B4": 493.88, "C5": 523.25, "D5": 587.33,
         "E5": 659.26, "F5": 698.46, "G5": 783.99, "A5": 880.00}
# (note, beats); None is a rest.
PART_A = [("E5", 1), ("B4", .5), ("C5", .5), ("D5", 1), ("C5", .5), ("B4", .5),
          ("A4", 1), ("A4", .5), ("C5", .5), ("E5", 1), ("D5", .5), ("C5", .5),
          ("B4", 1.5), ("C5", .5), ("D5", 1), ("E5", 1),
          ("C5", 1), ("A4", 1), ("A4", 1), (None, 1)]
PART_B = [(None, .5), ("D5", 1), ("F5", .5), ("A5", 1), ("G5", .5), ("F5", .5),
          ("E5", 1.5), ("C5", .5), ("E5", 1), ("D5", .5), ("C5", .5),
          ("B4", 1), ("B4", .5), ("C5", .5), ("D5", 1), ("E5", 1),
          ("C5", 1), ("A4", 1), ("A4", 1), (None, 1)]


def main():
    beat = 60.0 / BPM
    print("(Korobeiniki on the Y stepper. F = f * 60 / 400, spindle off)")
    print("G21")
    print("G90")
    print("M5")
    print(f"G53 G1 Y{START_Y:.3f} F1000")
    print("G4 P0.5")
    print("G91")
    direction = -1
    for note, beats in PART_A + PART_B + PART_A:
        seconds = beats * beat
        if note is None:
            print(f"G4 P{seconds:.3f}")
            continue
        feed = NOTES[note] * 60.0 / STEPS_PER_MM
        print(f"G1 Y{direction * feed / 60.0 * seconds:.3f} F{feed:.2f} ({note})")
        direction = -direction
    print("G90")
    print("G53 G1 Y-0.500 F1000")


if __name__ == "__main__":
    main()
