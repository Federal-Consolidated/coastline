"""The Control page's model against the simulated mill: connect, home, unlock, jog, zero,
undo, go to and a saved program (the Swift app's `mill …` automation commands)."""

import os
import time

import pytest
from PySide6.QtCore import QCoreApplication

os.environ["COASTLINE_SCRIPT"] = "1"  # never real ports, no saved preferences


@pytest.fixture(scope="module")
def qt():
    return QCoreApplication.instance() or QCoreApplication([])


def wait(qt, until, seconds=15.0):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        qt.processEvents()
        if until():
            return True
        time.sleep(0.02)
    return False


def test_simulated_machine_end_to_end(qt):
    from coastline_app.core.machine.profile import MachineProfile
    from coastline_app.model.mill_control import MillControl
    from coastline_app.model.settings import AppSettings

    mill = MillControl(AppSettings(), MachineProfile.standard())
    try:
        assert mill.state["stateWord"] == "Not connected"
        mill.connectSimulator()
        assert wait(qt, lambda: mill.state.get("link") == "connected" and mill.state["stateWord"] not in ("Connecting",))
        assert wait(qt, lambda: mill.canHome)  # the Home button is enabled
        mill.requestHome()  # simulated: no confirmation
        assert wait(qt, lambda: mill.state.get("homed") is True, 30)
        mill.allowJog = True
        before = mill.state["machine"]
        mill.jogStep = 10.0
        mill.jog(0, -1, 0)
        assert wait(qt, lambda: mill.state["machine"][1] != before[1] and mill.state["stateWord"] == "Idle", 20), mill.state
        mill.zero("XY")
        assert wait(qt, lambda: mill.state["work"][0] in ("0", "-0") and mill.state["work"][1] in ("0", "-0"), 10), mill.state["work"]
        assert mill.offsetUndo == "Zero X Y"
        mill.undoOffset()
        assert wait(qt, lambda: mill.offsetUndo == "")
        # The go-to form starts from the shown work position: wait until it shows the undone offset.
        assert wait(qt, lambda: mill.state["work"][0] not in ("0", "-0"), 10), mill.state["work"]
        assert wait(qt, lambda: mill.state["gates"]["run"] == "")
        mill.requestGoTo("position")
        mill.setGoToField("z", -5)
        plan = mill.goToPlan()
        assert plan["ok"], plan
        # The controller may still be answering the offset write: a click a moment later goes.
        assert wait(qt, lambda: mill.go(), 10), mill.message
        assert wait(qt, lambda: mill.state["stateWord"] == "Idle" and mill.state.get("program") and mill.state["program"]["kind"] == "completed", 20)
        assert wait(qt, lambda: mill.state["gates"]["run"] == "")
        why = mill.saveProgram("", "Square", "", "G53 G0 X-40 Y-100\nG53 G0 X-41 Y-100\n", "motionCheck")
        assert why == ""
        p = next(p for p in mill.programs if p["title"] == "Square")
        mill.confirmProgram(p["id"])
        assert mill.checkConfirm()["ok"], mill.checkConfirm()
        assert wait(qt, lambda: mill.runConfirmed(), 10), mill.message
        assert wait(qt, lambda: mill.state["program"]["name"] == "Square" and mill.state["program"]["kind"] == "completed", 20)
        assert any(l["kind"] == "sent" for l in mill.console)
    finally:
        mill.disconnect()
        mill.shutdown()
