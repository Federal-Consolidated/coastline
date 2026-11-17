"""The whole job through the workspace model, headless, on a fresh data folder: part → stock →
analysis → plans → generation → posting and checks → save → reopen."""

import os
import subprocess
import sys
import textwrap
from pathlib import Path

APP = Path(__file__).resolve().parents[1]

SCRIPT = textwrap.dedent("""
    import os, sys, faulthandler
    faulthandler.dump_traceback_later(600, exit=True)
    from pathlib import Path
    from PySide6.QtGui import QGuiApplication
    app = QGuiApplication([])
    from coastline_app import paths
    from coastline_app.core.plan.setup import Workholding
    from coastline_app.model.inventory_model import InventoryModel
    from coastline_app.model.journal_model import JournalModel
    from coastline_app.model.settings import AppSettings
    from coastline_app.model.tasks import spawn
    from coastline_app.model.workspace import Workspace

    inv = InventoryModel()
    w = Workspace(inv, JournalModel(), AppSettings(), None)
    result = {}
    project = Path(os.environ["COASTLINE_DATA_DIR"]) / "e2e.coastline"

    def run():
        yield from w.load_machine()
        yield from w.import_part(paths.SAMPLES_DIR / "pendant.step")
        choices = w.guided_stock_choices(inv.inventory)
        w.use_guided_stock(choices[0].stock, inv.inventory)
        def custom(s):
            s.holding = Workholding.CUSTOM
            s.plan_from_fixture_library = False
        w.change_setup(custom)
        yield from w.run_analysis()
        w.enter("planning")
        yield from w.find_plans(inv.inventory)
        w.use_plan(next(c for c in w.plan_options if c.name == w.recommended_plan))
        yield from w.generate_toolpaths(inv.inventory)
        result["programs"] = len(w.programs)
        result["passed"] = all(p.report.passed for p in w.programs)
        result["error"] = w.errorMessage
        w.save_project(project)
        w2 = Workspace(inv, JournalModel(), AppSettings(), None)
        yield from w2.open_project(project)
        result["reopened"] = len(w2.programs)
        app.quit()

    def fail(e):
        import traceback; traceback.print_exception(e); app.quit()

    spawn(run(), "e2e", on_error=fail)
    app.exec()
    print(result)
    ok = result.get("programs", 0) > 0 and result["passed"] and not result["error"] and result.get("reopened") == result["programs"]
    os._exit(0 if ok else 4)
""")


def test_whole_job_end_to_end(tmp_path):
    env = dict(os.environ, COASTLINE_SCRIPT="1", COASTLINE_DATA_DIR=str(tmp_path), COASTLINE_CACHE_DIR=str(tmp_path / "cache"),
               QT_QPA_PLATFORM="offscreen")
    result = subprocess.run([sys.executable, "-c", SCRIPT], cwd=APP, env=env, capture_output=True, text=True, timeout=900)
    assert result.returncode == 0, result.stdout[-4000:] + result.stderr[-4000:]
