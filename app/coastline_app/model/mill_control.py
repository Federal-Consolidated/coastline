"""The app's link to the machine: owns the `MillSession` (which does all the I/O on its own
thread) and copies its snapshot and console for the screens ten times a second.
Port of Model/MillControl.swift (and the GoToRequest helpers of Views/Control/ManualControls.swift)."""

from __future__ import annotations

import json
import os
import re
import time
from dataclasses import dataclass

from PySide6.QtCore import QObject, QTimer, Slot

from ..core.units import DisplayUnits
from ..mill.geometry import Axis, Point3
from ..mill.programs import (GoToFrame, SavedProgramKind, SavedTestProgram, TestProgram, TestProgramLibrary,
                             check_job_program, check_test_program, go_to_lines)
from ..mill.session import JOG_FEEDS, JOG_STEPS, MillSession
from ..mill.session_types import (JogRequest, MillLink, MillOverride, MillPort, MillRefusal, MillSnapshot,
                                  ProgramOutcome)
from .bindable import prop
from .settings import AppSettings

SCRIPTED = "COASTLINE_SCRIPT" in os.environ
DEV = os.environ.get("COASTLINE_DEV") == "1"
PROGRAM_EXTENSIONS = ["nc", "gcode", "ngc", "tap", "cnc", "txt"]


@dataclass
class GoToRequest:
    title: str
    x: float | None = None
    y: float | None = None
    z: float | None = None
    frame: GoToFrame = GoToFrame.WORK
    retract_first: bool = True
    fixed_lines: list[str] | None = None  # fixed moves instead of a target (tool change)

    def to_qml(self) -> dict:
        return {"title": self.title, "x": self.x, "y": self.y, "z": self.z, "frame": self.frame.value,
                "retractFirst": self.retract_first, "fixed": self.fixed_lines is not None}


def _describe(line: str, units: DisplayUnits) -> str | None:
    """One move in words: "Spindle off", "Rapid to machine X −40 Y −100 mm"."""
    if line == "M5":
        return "Spindle off"
    if "G53" not in line:
        return None
    words = [f"{a} {units.format(float(v))}" for a, v in re.findall(r"([XYZ])(-?[0-9.]+)", line)]
    return "Rapid to machine " + " ".join(words) + " " + units.symbol


AUTO_RETRY_DELAYS = (1.0, 2.0, 5.0)  # seconds before trying a failed automatic connect again


class MillControl(QObject):
    state, stateChanged = prop("QVariantMap", "state", {})
    console, consoleChanged = prop("QVariantList", "console", [])
    ports, portsChanged = prop("QVariantList", "ports", [])
    portChoice, portChoiceChanged = prop(str, "portChoice", "auto", on_set=lambda s, v: s._save_choice(v))
    autoConnect, autoConnectChanged = prop(bool, "autoConnect", True,
                                           on_set=lambda s, v: None if SCRIPTED else AppSettings.set_value("millAutoConnect", v))
    jogStep, jogStepChanged = prop(float, "jogStep", 1.0)
    jogFeed, jogFeedChanged = prop(float, "jogFeed", 1000.0)
    jogHold, jogHoldChanged = prop(bool, "jogHold", False, on_set=lambda s, v: s.endHold())
    allowJog, allowJogChanged = prop(bool, "allowJog", False, on_set=lambda s, v: s._jog_lock_changed(v))
    holding, holdingChanged = prop(bool, "holding", False)  # a hold-to-jog button or key is down
    heldKey, heldKeyChanged = prop(str, "heldKey", "")  # which pad target holds ("x-1", "z1" …)
    message, messageChanged = prop(str, "message", "")
    showHomeConfirm, showHomeConfirmChanged = prop(bool, "showHomeConfirm", False)
    showSpindleConfirm, showSpindleConfirmChanged = prop(bool, "showSpindleConfirm", False)
    showConsole, showConsoleChanged = prop(bool, "showConsole", False)
    showProgramLibrary, showProgramLibraryChanged = prop(bool, "showProgramLibrary", False)
    programToConfirm, programToConfirmChanged = prop("QVariantMap", "programToConfirm", {})
    goTo, goToChanged = prop("QVariantMap", "goTo", {})
    spindleRPM, spindleRPMChanged = prop(float, "spindleRPM", 5000.0)
    offsetUndo, offsetUndoChanged = prop(str, "offsetUndo", "")  # what Undo would revert ("Zero X")
    programs, programsChanged = prop("QVariantList", "programs", [])
    canHome, canHomeChanged = prop(bool, "canHome", False)
    canRun, canRunChanged = prop(bool, "canRun", False)
    canResume, canResumeChanged = prop(bool, "canResume", False)

    def __init__(self, settings: AppSettings, control_machine, parent: QObject | None = None) -> None:
        super().__init__(parent)
        self.settings = settings
        self.control_machine = control_machine
        self.session = MillSession()
        self.snapshot = MillSnapshot()
        self._console_lines = []
        self._last_console_id = 0
        self._last_scan = 0.0
        self._hold_started: float | None = None
        self._held: tuple[float, float, float] | None = None
        self._auto_skip: set[str] = set()  # the operator disconnected: not until it is plugged in again
        # Automatic connects tried per port: a freshly plugged board may not open at once, so a failed
        # one is tried again after 1, 2 and 5 s, then left until it is plugged in again.
        self._auto_attempts: dict[str, tuple[int, float]] = {}
        self._undo: tuple[int, Point3, str] | None = None
        self._go: GoToRequest | None = None
        self._confirm: SavedTestProgram | None = None
        self._setup_check = None
        self._library = self._load_programs()
        self._loading = True
        choice = str(AppSettings.value("millPort", "auto"))
        self.portChoice = choice
        self.autoConnect = bool(AppSettings.value("millAutoConnect", True))
        self._loading = False
        self.refreshPorts()
        self._publish_programs()
        self._publish()
        self._timer = QTimer(self)
        self._timer.setInterval(100)
        self._timer.timeout.connect(self._pull)
        self._timer.start()
        if DEV:
            self.connectSimulator()

    # ------------------------------------------------------------ derived

    @property
    def units(self) -> DisplayUnits:
        return self.settings.display_units

    @property
    def is_open(self) -> bool:
        return self.snapshot.is_open

    @property
    def is_simulated(self) -> bool:
        return self.snapshot.port is not None and self.snapshot.port.is_simulated

    def state_word(self) -> str:
        s = self.snapshot
        if s.link is MillLink.DISCONNECTED:
            return "Not connected"
        if s.link is MillLink.CONNECTING:
            return "Connecting"
        if s.silent_since is not None:
            return "No reply"
        if s.homing_since is not None:
            return "Homing"
        return s.status.state.split(":")[0] if s.status is not None else "Connected"

    def notice(self) -> str:
        s = self.snapshot
        if s.silent_since is not None:
            return MillRefusal("silent").text
        if s.needs_reset:
            return "Reset the controller, then home the machine."
        if s.last_alarm:
            return s.last_alarm
        if s.gates.home is not None and s.gates.home.code == "settings":
            return s.gates.home.text
        if s.last_error:
            return s.last_error
        if self.message:
            return self.message
        if s.status is not None and s.status.probe_tripped:
            return "Probe contact detected. Release the contact before continuing."
        if s.homing_since is not None:
            return "Homing the machine…"
        if s.link is MillLink.CONNECTED and not s.homed:
            return "Home the machine before jogging."
        if s.gates.jog is not None and s.is_open and self._held is None:
            return s.gates.jog.text
        return ""

    def _publish(self) -> None:
        s, u = self.snapshot, self.units
        work = s.work_position if s.is_open else None
        mach = s.status.machine_position if s.is_open and s.status is not None else None

        def coords(p) -> list[str]:
            return [u.format(p.x), u.format(p.y), u.format(p.z)] if p is not None else ["—", "—", "—"]

        program = None
        if s.program is not None:
            p = s.program
            end = p.finished_at or time.time()
            outcome = {ProgramOutcome.RUNNING: "Running", ProgramOutcome.COMPLETED: "Done",
                       ProgramOutcome.STOPPED: "Stopped"}.get(p.outcome, f"Stopped: {p.failure}")
            program = {"name": p.name, "fraction": p.fraction, "done": p.done, "total": p.total,
                       "seconds": round(end - p.started_at), "outcome": outcome,
                       "kind": p.outcome.name.lower()}
        status = s.status
        spindle = s.spindle
        word = self.state_word()
        self.state = {
            "open": s.is_open, "simulated": self.is_simulated, "link": s.link.value, "homed": s.homed,
            "homing": s.homing_since is not None, "needsReset": s.needs_reset, "stateWord": word,
            "stateKind": ("ok" if word == "Idle" else "danger" if word in ("Alarm", "No reply") else
                          "warning" if word in ("Hold", "Door") else "active" if word in ("Run", "Jog", "Home", "Homing") else ""),
            "notice": self.notice(), "probe": "Probe: —" if not (s.is_open and status) else
            ("Probe: Contact" if status.probe_tripped else "Probe: Open"),
            "probeTripped": bool(status and status.probe_tripped),
            "work": coords(work), "machine": coords(mach), "activeWCS": s.active_wcs,
            "gates": {k: (getattr(s.gates, k).text if getattr(s.gates, k) is not None else "")
                      for k in ("home", "jog", "resume", "console", "run", "setup")},
            "program": program,
            "spindle": ("—" if not s.is_open or spindle is None else "Off" if spindle[0] == "M5" else f"On, {spindle[1]:.0f} RPM"),
            "overrides": {"feed": s.overrides.feed, "rapid": s.overrides.rapid, "spindle": s.overrides.spindle},
            "firmware": s.firmware or "", "parserState": s.parser_state or "",
            "buffer": f"{status.free_planner_blocks} blocks / {status.free_rx_bytes} bytes" if status else "",
            "limits": (", ".join(a for a, on in (("X", status.limit_x), ("Y", status.limit_y), ("Z", status.limit_z)) if on) or "Open") if status else "",
            "reportedFeed": f"{u.format(float(status.feed_rate))} {u.symbol}/min" if status and status.feed_rate is not None else "",
            "reportedSpindle": f"{status.spindle_speed or 0} RPM" if status and status.feed_rate is not None else "",
            "offsets": [{"name": o.name, "text": f"{o.name}  {u.format(o.point.x)}  {u.format(o.point.y)}  {u.format(o.point.z)} {u.symbol}"}
                        for o in s.offsets if o.name.startswith("G5")],
            "portLabel": s.port.label if s.port is not None else "",
            "unit": u.symbol, "homeTarget": s.home_target is not None,
        }

    # ------------------------------------------------------------ connection

    def _save_choice(self, value: str) -> None:
        if not SCRIPTED and not getattr(self, "_loading", False):
            AppSettings.set_value("millPort", value)

    @Slot()
    def refreshPorts(self) -> None:
        self._ports = MillSession.available_ports()
        self.ports = [{"path": d.path, "label": d.path.replace("/dev/", "")} for d in self._ports]

    @Slot()
    def connect(self) -> None:
        self.message = ""
        choice = self.portChoice
        if choice == "sim":
            port = MillPort.simulated()
        elif choice == "auto":
            self.refreshPorts()
            if len(self._ports) != 1:
                self.message = ("No machine found. Check the USB cable and that the mill is on." if not self._ports
                                else "More than one mill is plugged in. Choose the port.")
                return
            port = MillPort(self._ports[0])
        else:
            self.refreshPorts()
            device = next((d for d in self._ports if d.path == choice), None)
            if device is None:
                self.message = f"{choice} is not plugged in."
                return
            port = MillPort(device)
        if (SCRIPTED or DEV) and not port.is_simulated:
            self.message = "UI development and scripted runs use Digital Machine only."
            return
        self._reset_console()
        self.session.connect(port)

    @Slot()
    def connectSimulator(self) -> None:
        """Opens the simulated mill without changing the chosen port. Never while a machine is connected."""
        if self.is_open:
            self.message = "" if self.is_simulated else "A machine is connected. Disconnect it to simulate."
            return
        self.message = ""
        self._reset_console()
        self.session.connect(MillPort.simulated())

    def _reset_console(self) -> None:
        self._console_lines = []
        self.console = []
        self.session.clear_console()
        self._last_console_id = 0

    @Slot()
    def disconnect(self) -> None:
        port = self.snapshot.port
        if port is not None and port.device is not None:
            self._auto_skip.add(port.device.path)  # not again until it is plugged in again
        self.allowJog = False
        self._held = None
        self.holding = False
        self._undo = None
        self.offsetUndo = ""
        self.session.disconnect()

    def shutdown(self) -> None:
        """App quit: stop the machine if it moves, then close the port."""
        self._timer.stop()
        self.session.shutdown()

    # ------------------------------------------------------------ motion

    def _report(self, refusal: MillRefusal | None) -> None:
        self.message = refusal.text if refusal is not None else ""

    @Slot()
    def requestHome(self) -> None:
        if self.is_simulated:
            self.home()
        else:
            self.showHomeConfirm = True

    @Slot()
    def home(self) -> None:
        self.allowJog = False
        self._report(self.session.home())

    def _jog_lock_changed(self, allowed: bool) -> None:
        if not allowed:
            self._held = None
            self.holding = False
            self.heldKey = ""
            self._hold_started = None
            self.session.jog_cancel()

    @Slot(float, float, float)
    def jog(self, x: float, y: float, z: float) -> None:
        """The pad's physical directions; diagonals travel together in one jog."""
        if not self.allowJog:
            self.message = "Unlock jogging first."
            return
        s = self.jogStep
        self._report(self.session.jog(JogRequest(x * s, y * s, z * s, self.jogFeed)))

    @Slot(float, float, float)
    def startHold(self, x: float, y: float, z: float) -> None:
        if self._held is not None:
            return
        if not self.allowJog:
            self.message = "Unlock jogging first."
            return
        refusal = self.session.start_hold(x, y, z, self.jogFeed)
        self._report(refusal)
        if refusal is None:
            self._held = (x, y, z)
            self.holding = True
            self.heldKey = f"{x:g},{y:g},{z:g}"
            self._hold_started = time.monotonic()

    @Slot()
    def endHold(self) -> None:
        if self._held is None:
            return
        self._held = None
        self.holding = False
        self.heldKey = ""
        self._hold_started = None
        self.session.end_hold()

    def set_work(self, values: dict, what: str) -> None:
        """Makes the current position these work coordinates (G10 L20); keeps the old offset for Undo."""
        wcs = self.snapshot.active_wcs
        before = self.snapshot.offset(wcs)
        refusal = self.session.set_work_position(values, wcs)
        self._report(refusal)
        if refusal is None and before is not None:
            self._undo = (wcs, before, what)
            self.offsetUndo = what

    @Slot(str)
    def zero(self, axes: str) -> None:
        picked = [a for a in (Axis.X, Axis.Y, Axis.Z) if a.value in axes.upper()]
        self.set_work({a: 0.0 for a in picked}, "Zero " + " ".join(a.value for a in picked))

    @Slot("QVariant", "QVariant", "QVariant")
    def setWork(self, x, y, z) -> None:
        values = {a: float(v) for a, v in ((Axis.X, x), (Axis.Y, y), (Axis.Z, z)) if v is not None}
        if values:
            self.set_work(values, "Set " + " ".join(sorted(a.value for a in values)))

    @Slot()
    def undoOffset(self) -> None:
        if self._undo is None:
            return
        wcs, before, _ = self._undo
        refusal = self.session.set_offset(before, wcs)
        self._report(refusal)
        if refusal is None:
            self._undo = None
            self.offsetUndo = ""

    @Slot(int)
    def selectWCS(self, wcs: int) -> None:
        self._report(self.session.select_wcs(wcs))

    @Slot()
    def spindleOn(self) -> None:
        self._report(self.session.spindle_on(self.spindleRPM))

    @Slot()
    def spindleOff(self) -> None:
        self._report(self.session.spindle_off())

    @Slot(str)
    def override(self, name: str) -> None:
        self.session.override(MillOverride[name])

    @Slot()
    def feedHold(self) -> None:
        self._held = None
        self.holding = False
        self.session.feed_hold()

    @Slot()
    def resume(self) -> None:
        self._report(self.session.resume())

    @Slot()
    def stop(self) -> None:
        self.allowJog = False
        self._held = None
        self.holding = False
        self.session.stop()

    @Slot()
    def softReset(self) -> None:
        self.allowJog = False
        self._held = None
        self.holding = False
        self.session.soft_reset()

    @Slot(str, result=bool)
    def send(self, line: str) -> bool:
        refusal = self.session.send_console(line)
        self._report(refusal)
        return refusal is None

    @Slot()
    def clearConsole(self) -> None:
        self._reset_console()

    # ------------------------------------------------------------ go to

    @Slot(str)
    def requestGoTo(self, which: str) -> None:
        s = self.snapshot
        if which == "workZero":
            r = GoToRequest("Go to work zero", 0.0, 0.0)
        elif which == "home":
            t = s.home_target
            if t is None:
                return
            r = GoToRequest("Go to the home position", t.x, t.y, t.z, GoToFrame.MACHINE)
        elif which == "toolChange":
            moves = [m for m in self.control_machine.tool_change_moves if m.upper().replace(" ", "") != "$H"]
            r = GoToRequest("Go to the tool-change position", fixed_lines=["G21", "G90", "M5"] + moves)
        else:
            w = s.work_position
            rnd = lambda v: round(v * 1000) / 1000  # noqa: E731
            r = GoToRequest("Go to a position", *(None, None, None) if w is None else (rnd(w.x), rnd(w.y), rnd(w.z)))
        self._go = r
        self.goTo = r.to_qml()

    @Slot(str, "QVariant")
    def setGoToField(self, key: str, value) -> None:
        r = self._go
        if r is None:
            return
        if key in ("x", "y", "z"):
            setattr(r, key, None if value is None or value == "" else float(value))
        elif key == "frame":
            r.frame = GoToFrame(value)
        elif key == "retractFirst":
            r.retract_first = bool(value)
        self.goTo = r.to_qml()

    def _go_lines(self, r: GoToRequest) -> list[str]:
        if r.fixed_lines is not None:
            return r.fixed_lines
        env = self.snapshot.envelope
        if env is None:
            raise MillRefusal("statusStale" if self.is_open else "notConnected")
        return go_to_lines(r.x, r.y, r.z, r.frame, self.snapshot.work_offset, env, r.retract_first)

    @Slot(result="QVariantMap")
    def goToPlan(self) -> dict:
        """The moves of the pending go-to in words, or why it can't run."""
        if self._go is None:
            return {}
        try:
            lines = self._go_lines(self._go)
        except MillRefusal as e:
            return {"ok": False, "why": e.text}
        return {"ok": True, "steps": [d for d in (_describe(l, self.units) for l in lines) if d],
                "code": "  ".join(lines)}

    @Slot(result=bool)
    def go(self) -> bool:
        if not self.allowJog:
            self.message = "Unlock jogging first."
            return False
        try:
            lines = self._go_lines(self._go)
        except MillRefusal as e:
            self._report(e)
            return False
        refusal = self.session.run(self._go.title, lines)
        self._report(refusal)
        if refusal is None:
            self._go = None
            self.goTo = {}
        return refusal is None

    @Slot()
    def cancelGoTo(self) -> None:
        self._go = None
        self.goTo = {}

    # ------------------------------------------------------------ test programs

    def _load_programs(self) -> TestProgramLibrary:
        raw = AppSettings.value("millTestPrograms", None)
        if raw:
            try:
                return TestProgramLibrary.from_json(json.loads(raw))
            except (ValueError, KeyError, TypeError):
                pass
        return TestProgramLibrary()

    def _publish_programs(self) -> None:
        self.programs = [{"id": p.id, "title": p.title, "detail": p.detail, "code": p.code, "favorite": p.is_favorite,
                          "kind": p.kind.value, "kindTitle": p.kind.title} for p in self._library.ordered]

    def _save_programs(self) -> None:
        if not SCRIPTED:
            AppSettings.set_value("millTestPrograms", json.dumps(self._library.to_json()))
        self._publish_programs()

    @Slot(str, str, str, str, str, result=str)
    def saveProgram(self, id: str, title: str, detail: str, code: str, kind: str) -> str:
        """Saves (or replaces) a program; returns why it can't be saved ("" = saved)."""
        p = SavedTestProgram(title, detail, code, kind=SavedProgramKind(kind), id=id or SavedTestProgram("x").id)
        old = next((q for q in self._library.programs if q.id == p.id), None)
        if old is not None:
            p.is_favorite = old.is_favorite
        why = p.validation_message
        if why:
            return why
        self._library.save(p)
        self._save_programs()
        return ""

    @Slot()
    def addBuiltIns(self) -> None:
        for t in TestProgram:
            self._library.save(SavedTestProgram.built_in(t))
        self._save_programs()

    @Slot(str)
    def removeProgram(self, id: str) -> None:
        self._library.remove(id)
        self._save_programs()

    @Slot(str)
    def favoriteProgram(self, id: str) -> None:
        self._library.toggle_favorite(id)
        self._save_programs()

    @Slot(str)
    def confirmProgram(self, id: str) -> None:
        p = next((q for q in self._library.programs if q.id == id), None)
        if p is not None:
            self._confirm = p
            self._publish_confirm()

    @Slot(str)
    def openProgramFile(self, path: str) -> None:
        """A G-code or NC file for a single run, checked like a guided job's program."""
        from pathlib import Path
        try:
            data = Path(path).read_bytes()
        except OSError:
            self.message = f"Couldn't read {Path(path).name}."
            return
        try:
            code = data.decode("utf-8")
        except UnicodeDecodeError:
            code = data.decode("latin-1")
        self._confirm = SavedTestProgram(Path(path).name, path, code, kind=SavedProgramKind.SETUP)
        self._publish_confirm()

    def _publish_confirm(self) -> None:
        p = self._confirm
        if p is None:
            self.programToConfirm = {}
            return
        lines = p.lines
        shown = "\n".join(f"{i + 1}\t{l}" for i, l in enumerate(lines[:400]))
        if len(lines) > 400:
            shown += f"\n… {len(lines) - 400} more lines"
        self.programToConfirm = {"id": p.id, "title": p.title, "detail": p.detail, "preview": shown,
                                 "motion": p.kind is SavedProgramKind.MOTION_CHECK}

    @Slot(result="QVariantMap")
    def checkConfirm(self) -> dict:
        """Whether the program waiting for confirmation can run now."""
        p = self._confirm
        if p is None:
            return {}
        try:
            self._check(p)
            return {"ok": True}
        except MillRefusal as e:
            return {"ok": False, "why": e.text}

    def _check(self, p: SavedTestProgram) -> list[str]:
        why = p.validation_message
        if why:
            raise MillRefusal("blocked", why)
        s = self.snapshot
        env = s.envelope
        if env is None:
            raise MillRefusal("statusStale" if s.is_open else "notConnected")
        if p.kind is SavedProgramKind.MOTION_CHECK:
            if s.gates.run is not None:
                raise s.gates.run
            if s.status is None:
                raise MillRefusal("statusStale")
            return check_test_program(p.lines, s.status.machine_position, env)
        key = (p.id, p.code, s.settings, env)
        if self._setup_check is not None and self._setup_check[0] == key:
            checked = self._setup_check[1]
        else:
            checked = check_job_program(p.lines, s.settings, env)
            self._setup_check = (key, checked)
        gate = s.gates.home if checked.starts_with_home else s.gates.run
        if gate is not None:
            raise gate
        return checked.lines

    @Slot(result=bool)
    def runConfirmed(self) -> bool:
        p = self._confirm
        if p is None:
            return False
        if p.validation_message:
            self.message = p.validation_message
            return False
        self.allowJog = False
        refusal = (self.session.run(p.title, p.lines) if p.kind is SavedProgramKind.MOTION_CHECK
                   else self.session.run_job(p.title, p.lines))
        self._report(refusal)
        if refusal is None:
            self._confirm = None
            self.programToConfirm = {}
        return refusal is None

    @Slot()
    def cancelConfirm(self) -> None:
        self._confirm = None
        self.programToConfirm = {}

    def run_job(self, name: str, lines: list[str]) -> bool:
        """One program of a guided job. Returns False (and sets `message`) if refused."""
        self.allowJog = False
        refusal = self.session.run_job(name, lines)
        self._report(refusal)
        return refusal is None

    # ------------------------------------------------------------ the 10 Hz pull

    def _pull(self) -> None:
        nxt = self.session.snapshot
        s = self.snapshot
        if nxt.revision != s.revision:
            doubt = (not nxt.homed or nxt.restarts != s.restarts or nxt.silent_since is not None
                     or nxt.link is not MillLink.CONNECTED or (nxt.last_alarm is not None and nxt.last_alarm != s.last_alarm))
            if doubt and self.allowJog:
                self.allowJog = False
            if self._held is not None and not nxt.holding and (s.holding or nxt.last_error != s.last_error):
                self.endHold()
            if nxt.link is MillLink.DISCONNECTED and s.link is not MillLink.DISCONNECTED:
                self.refreshPorts()
            self.snapshot = nxt
            self.canHome = nxt.gates.home is None
            self.canResume = nxt.gates.resume is None
            self.canRun = nxt.gates.run is None
            self._publish()
            if self._confirm is not None:
                self.programToConfirmChanged.emit()  # the sheet re-checks against the new state
            if self._go is not None:
                self.goToChanged.emit()
        # A hold lasts while it is renewed: if this timer stops (the app hangs), the session
        # cancels the jog by itself.
        if self._held is not None:
            if not nxt.holding and self._hold_started is not None and time.monotonic() - self._hold_started > 0.5:
                self.endHold()
            elif self.allowJog and self.is_open:
                self.session.renew_hold()
            else:
                self.endHold()
        self._auto_connect()
        lines = self.session.console(self._last_console_id)
        if lines:
            self._last_console_id = lines[-1].id
            self._console_lines = (self._console_lines + [{"id": l.id, "kind": l.kind.value, "text": l.text} for l in lines])[-1000:]
            self.console = self._console_lines

    def _auto_connect(self) -> None:
        """Once a second while not connected: a machine plugged in is connected (once per plug-in)."""
        now = time.monotonic()
        if now - self._last_scan < 1 or SCRIPTED or DEV:
            return
        self._last_scan = now
        if self.is_open:
            self._auto_attempts.clear()  # connected: a later unplug starts afresh
            return
        found = MillSession.available_ports()
        if found != self._ports:
            # Port diagnostics in the console: which mills appeared and went, with their USB IDs.
            for d in found:
                if d not in self._ports:
                    self.session.note_in_console(f"Port found: {d.diagnostics}")
            for d in self._ports:
                if d not in found:
                    self.session.note_in_console(f"Port removed: {d.path}")
            if len(found) > 1 and self.portChoice == "auto":
                self.session.note_in_console(f"{len(found)} mills are plugged in: choose one under Diagnostics → Port to connect.")
            self._ports = found
            self.ports = [{"path": d.path, "label": d.path.replace("/dev/", "")} for d in found]
        self._auto_skip &= {d.path for d in found}  # unplugged: may connect again when it is back
        paths = {d.path for d in found}
        self._auto_attempts = {k: v for k, v in self._auto_attempts.items() if k in paths}
        if not self.autoConnect:
            return
        if self.portChoice == "auto":
            device = found[0] if len(found) == 1 else None
        elif self.portChoice == "sim":
            device = None
        else:
            device = next((d for d in found if d.path == self.portChoice), None)
        if device is None or device.path in self._auto_skip:
            return
        count, next_at = self._auto_attempts.get(device.path, (0, 0.0))
        if count > len(AUTO_RETRY_DELAYS) or now < next_at:
            return
        if count:
            self.session.note_in_console(f"Trying {device.path} again ({count} of {len(AUTO_RETRY_DELAYS)}).")
        self._auto_attempts[device.path] = (count + 1, now + AUTO_RETRY_DELAYS[min(count, len(AUTO_RETRY_DELAYS) - 1)])
        self.connect()

    @Slot(result="QVariantList")
    def jogSteps(self) -> list[dict]:
        return [{"value": s, "title": self.units.format(s, 6)} for s in JOG_STEPS]

    @Slot(result="QVariantList")
    def jogFeeds(self) -> list[dict]:
        return [{"value": f, "title": f"{self.units.format(f)} {self.units.symbol}/min"} for f in JOG_FEEDS]
