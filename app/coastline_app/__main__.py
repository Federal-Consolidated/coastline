"""Starts Coastline: `uv run coastline` or `python -m coastline_app` (from app/).

Optional: `coastline path/to/part.step` opens a part at launch.
"""

from __future__ import annotations

import sys
from pathlib import Path

from PySide6.QtCore import QTimer

from .application import create_app


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv if argv is None else argv
    app = create_app(argv)
    app.backend.start()

    part = next((Path(a) for a in argv[1:] if not a.startswith("-")), None)
    if part is not None:
        from .model.tasks import spawn
        QTimer.singleShot(200, lambda: spawn(app.backend.open_path_task(part.resolve()), "open"))

    code = app.qt.exec()
    app.root.shutdown()  # a moving machine is stopped before the port closes
    del app.qml  # the screens go before the models they bind to
    return code


if __name__ == "__main__":
    sys.exit(main())
