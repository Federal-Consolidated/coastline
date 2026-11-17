import time

import pytest
from PySide6.QtCore import QCoreApplication

from coastline_app.model.tasks import Cancelled, Sleep, Work, spawn


@pytest.fixture(scope="module")
def qt():
    return QCoreApplication.instance() or QCoreApplication([])


def run_until(qt, cond, seconds=5):
    end = time.monotonic() + seconds
    while time.monotonic() < end and not cond():
        qt.processEvents()
        time.sleep(0.005)
    return cond()


def test_work_runs_off_the_ui_thread_and_resumes_on_it(qt):
    import threading
    seen = []

    def job():
        a = yield Work(lambda: (threading.current_thread().name, 2))
        seen.append(threading.current_thread() is threading.main_thread())
        b = yield Work(lambda: a[1] * 21, lane="other")
        yield Sleep(0.01)
        return b

    t = spawn(job())
    assert run_until(qt, lambda: t.finished)
    assert t.result == 42 and seen == [True]


def test_errors_are_thrown_into_the_task_and_cancel_stops_it(qt):
    caught = []

    def failing():
        try:
            yield Work(lambda: 1 / 0)
        except ZeroDivisionError:
            caught.append("caught")
        return "ok"

    t = spawn(failing())
    assert run_until(qt, lambda: t.finished) and t.result == "ok" and caught == ["caught"]

    steps = []

    def long():
        try:
            while True:
                steps.append(1)
                yield Sleep(0.01)
        except Cancelled:
            steps.append("cancelled")
            raise

    t2 = spawn(long())
    assert run_until(qt, lambda: len(steps) >= 3)
    t2.cancel()
    assert run_until(qt, lambda: t2.finished)
    assert steps[-1] == "cancelled" and t2.error is None


def test_a_task_can_wait_for_another(qt):
    def inner():
        v = yield Work(lambda: 5)
        return v + 1

    def outer():
        t = spawn(inner())
        r = yield t
        return r * 2

    t = spawn(outer())
    assert run_until(qt, lambda: t.finished) and t.result == 12
