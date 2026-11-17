"""Errors thrown while talking to the mill, and errors/alarms shown to the user.
Port of MillError.swift (`MillException`, `MillingError` in the original)."""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum


class MillErrorKind(Enum):
    NO_ACCESS = "no access to /dev"
    NO_DEVICE = "no machine found"
    FAILED_OPEN = "failed to open connection to the machine"
    FAILED_GET = "failed to get properties of the machine"
    FAILED_SET = "failed to set properties of the machine"
    FAILED_WRITE = "failed to write to the machine"
    NOT_TTY = "not a tty connection"
    NOT_OPEN = "connection to the machine not open"
    GRBL_ERROR = "Not a valid GRBL command."
    ALARM = "Alarm: unknown"
    ALARM_LIMIT = "Alarm: hard/soft limit hit"
    ALARM_PROBE = "Alarm: probe fail"
    UNKNOWN_COMMAND = "Not a recognized G/M/$ or other command"
    M100_OUT_OF_RANGE = "M100 value out of range"
    M101_FAIL = "M101 tolerance check failed"
    M102_INVALID_EXPRESSION = "M102 invalid expression"
    M102_OFFSETS_FAIL = "M102 could not read offsets"
    M102_INVALID_DEST_REGISTER = "M102 invalid destination register"
    M106_BOOL_TEST_FAIL = "M106 check failed"
    M106_MALFORMED_TEST = "M106 malformed test"
    M112_FAIL = "M112 failed"
    TIMEOUT = "timeout"
    NO_PROBE_COORD = "no probe coordinate"
    INVALID_MODE = "invalid mode"
    SOFTWARE_ESTOP = "Software emergency stop"
    ESTOP_PUSHED = "Emergency stop pushed"
    MACHINE_LOCKED = "Machine locked"


class MillError(Exception):
    def __init__(self, kind: MillErrorKind, detail: str = "") -> None:
        self.kind = kind
        self.detail = detail
        super().__init__(self.description)

    @property
    def type_message(self) -> str:
        return self.kind.value

    @property
    def description(self) -> str:
        if self.kind is MillErrorKind.M106_BOOL_TEST_FAIL:
            return self.detail
        return self.type_message if not self.detail else f"{self.type_message}: {self.detail}"

    def __str__(self) -> str:
        return self.description

    def __eq__(self, other: object) -> bool:
        return isinstance(other, MillError) and (self.kind, self.detail) == (other.kind, other.detail)

    def __hash__(self) -> int:
        return hash((self.kind, self.detail))


K = MillErrorKind

ERROR_CODES: dict[int, tuple[str, str]] = {
    1: ("Expected command letter", "G-code words consist of a letter and a value. Letter was not found."),
    2: ("Bad number format", "Missing the expected G-code word value or numeric value format is not valid."),
    3: ("Invalid statement", "Grbl '$' system command was not recognized or supported."),
    4: ("Value < 0", "Negative value received for an expected positive value."),
    5: ("Setting disabled", "Homing cycle failure. Homing is not enabled via settings."),
    6: ("Value < 3 usec", "Minimum step pulse time must be greater than 3usec."),
    7: ("EEPROM read fail. Using defaults", "An EEPROM read failed. Auto-restoring affected EEPROM to default values."),
    8: ("Not idle", "Grbl '$' command cannot be used unless Grbl is IDLE. Ensures smooth operation during a job."),
    9: ("G-code lock", "G-code commands are locked out during alarm or jog state."),
    10: ("Homing not enabled", "Soft limits cannot be enabled without homing also enabled."),
    11: ("Line overflow", "Max characters per line exceeded. Received command line was not executed."),
    12: ("Step rate > 30kHz", "Grbl '$' setting value cause the step rate to exceed the maximum supported."),
    13: ("Check Door", "Safety door detected as opened and door state initiated."),
    14: ("Line length exceeded", "Build info or startup line exceeded EEPROM line length limit. Line not stored."),
    15: ("Travel exceeded", "Jog target exceeds machine travel. Jog command has been ignored."),
    16: ("Invalid jog command", "Jog command has no '=' or contains prohibited g-code."),
    17: ("Setting disabled", "Laser mode requires PWM output."),
    20: ("Unsupported command", "Unsupported or invalid g-code command found in block."),
    21: ("Modal group violation", "More than one g-code command from same modal group found in block."),
    22: ("Undefined feed rate", "Feed rate has not yet been set or is undefined."),
    23: ("Invalid gcode ID:23", "G-code command in block requires an integer value."),
    24: ("Invalid gcode ID:24", "More than one g-code command that requires axis words found in block."),
    25: ("Invalid gcode ID:25", "Repeated g-code word found in block."),
    26: ("Invalid gcode ID:26", "No axis words found in block for g-code command or current modal state which requires them."),
    27: ("Invalid gcode ID:27", "Line number value is invalid."),
    28: ("Invalid gcode ID:28", "G-code command is missing a required value word."),
    29: ("Invalid gcode ID:29", "G59.x work coordinate systems are not supported."),
    30: ("Invalid gcode ID:30", "G53 only allowed with G0 and G1 motion modes."),
    31: ("Invalid gcode ID:31", "Axis words found in block when no command or current modal state uses them."),
    32: ("Invalid gcode ID:32", "G2 and G3 arcs require at least one in-plane axis word."),
    33: ("Invalid gcode ID:33", "Motion command target is invalid."),
    34: ("Invalid gcode ID:34", "Arc radius value is invalid."),
    35: ("Invalid gcode ID:35", "G2 and G3 arcs require at least one in-plane offset word."),
    36: ("Invalid gcode ID:36", "Unused value words found in block."),
    37: ("Invalid gcode ID:37", "G43.1 dynamic tool length offset is not assigned to configured tool length axis."),
    38: ("Invalid gcode ID:38", "Tool number greater than max supported value."),
}


class MillingErrorKind(Enum):
    ALARM = "alarm"
    ERROR = "error"


@dataclass(frozen=True)
class MillingError:
    """An error or alarm shown to the user."""

    kind: MillingErrorKind
    id: int
    title: str
    description: str

    ALARM_ESTOP = 50
    ALARM_TIMEOUT = 51
    ALARM_SOFT_ESTOP = 52
    ALARM_MACHINE_LOCKED = 53

    @property
    def allows_retry(self) -> bool:
        return self.is_probe_failure

    @property
    def is_probe_failure(self) -> bool:
        return self.kind is MillingErrorKind.ALARM and self.id in (4, 5)

    @property
    def is_not_idle(self) -> bool:
        return self.kind is MillingErrorKind.ERROR and self.id == 8

    @property
    def is_homing_failure(self) -> bool:
        return self.kind is MillingErrorKind.ALARM and 6 <= self.id <= 9

    @property
    def is_soft_limit_alarm(self) -> bool:
        return self.kind is MillingErrorKind.ALARM and self.id == 2

    @property
    def is_estop(self) -> bool:
        return self.kind is MillingErrorKind.ALARM and self.id == MillingError.ALARM_ESTOP

    @staticmethod
    def error(code: int, last_command=None) -> "MillingError":
        message, detail = ERROR_CODES.get(code, ("Error", "Unknown error occurred."))
        command = f'Command "{last_command.cleaned}"' if last_command is not None else "Command"
        description = (f"{command} returned error {code}: {message}: {detail}"
                       "\n\nIf this is a known good .crproj file, then a data transmission error occurred. If this is development code, try enabling check code mode to verify all g-code syntax is valid."
                       "\n\nUnfortunately g-code behavior after experiencing an error is undefined, so the sender cannot continue. Please try again.")
        return MillingError(MillingErrorKind.ERROR, code, message, description)

    @staticmethod
    def alarm(code: int) -> "MillingError":
        description = ALARM_CODES.get(code, "Unknown alarm occurred")
        if code < 50:
            if code in (4, 5):
                description = (f"The machine stopped with ALARM:{code} {description}\n\nPre-probing position and state has been preserved. "
                               "You may try again. Ensure probe wire is plugged in and that workpiece is free of chips and debris.")
            else:
                description = f"The machine stopped with ALARM:{code} {description}\n\nUnfortunately the sender cannot continue. Please try again."
        return MillingError(MillingErrorKind.ALARM, code, "Alarm", description)


ALARM_CODES: dict[int, str] = {
    1: "Hard limit triggered. Machine position is likely lost due to sudden and immediate halt. Re-homing is highly recommended.",
    2: "G-code motion target exceeds machine travel. Machine position safely retained. Alarm may be unlocked.",
    3: "Reset while in motion. Grbl cannot guarantee position. Lost steps are likely. Re-homing is highly recommended.",
    4: "Probe fail. The probe is not in the expected initial state before starting probe cycle, where G38.2 and G38.3 is not triggered and G38.4 and G38.5 is triggered.",
    5: "Probe fail. Probe did not contact the workpiece within the programmed travel for G38.2 and G38.4.",
    6: "Homing fail. Reset during active homing cycle.",
    7: "Homing fail. Safety door was opened during active homing cycle.",
    8: "Homing fail. Cycle failed to clear limit switch when pulling off. Try increasing pull-off setting or check wiring.",
    9: "Homing fail. Could not find limit switch within search distance. Defined as 1.5 * max_travel on search and 5 * pulloff on locate phases.",
    MillingError.ALARM_ESTOP: "Job was aborted due to pressing the emergency stop button. To reconnect, please twist the red emergency stop switch clockwise until it pops out. After resetting the button, press 'OK' to start program from the very beginning.",
    MillingError.ALARM_TIMEOUT: "Operation timed out.\n\nUnfortunately the sender cannot continue. Please try again.",
    MillingError.ALARM_SOFT_ESTOP: "Job was aborted due to pressing the software emergency stop button.",
    MillingError.ALARM_MACHINE_LOCKED: "Machine is locked. Reset to continue.",
}
