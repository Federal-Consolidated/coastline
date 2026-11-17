"""Line-oriented access to the mill and the "Machine Output" log. Port of SerialConnection.swift."""

from __future__ import annotations

import threading
from dataclasses import dataclass
from enum import Enum

from .state import ConnectionState
from .support import sleep_ms


class LogKind(Enum):
    READ = "READ"
    WRITE = "WRITE"
    ERROR = "ERROR"


@dataclass(frozen=True)
class LogEntry:
    kind: LogKind
    text: str


class MachineLog:
    """Lines read from / written to the mill plus errors. The UI drains it periodically."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._entries: list[LogEntry] = []

    def add(self, kind: LogKind, text: str) -> None:
        with self._lock:
            self._entries.append(LogEntry(kind, text))

    def drain(self) -> list[LogEntry]:
        with self._lock:
            entries, self._entries = self._entries, []
            return entries

    def clear(self) -> None:
        with self._lock:
            self._entries.clear()


class SerialConnection:
    def __init__(self, transport, state: ConnectionState, log: MachineLog) -> None:
        self.transport = transport
        self.state = state
        self.log = log
        # Recursive, like the original's connection mutex, so compound operations can nest.
        self.lock = threading.RLock()
        self._pending = bytearray()
        self._read_buffer = bytearray()
        self._show_status = False

    def connect(self) -> None:
        with self.lock:
            self._pending.clear()
            self._read_buffer.clear()
        self.transport.open()

    def disconnect(self) -> None:
        self.transport.close()

    def write_char(self, byte: int, wait_ms: int = 0) -> None:
        """Sends one real-time byte. It bypasses the line lock (GRBL accepts them mid-line), so
        an e-stop or feed hold is never delayed behind a long exchange."""
        self.transport.write(bytes([byte]))
        sleep_ms(wait_ms)

    def write_line(self, line: str, wait_ms: int = 0) -> None:
        """Sends `line` + newline, logging it unless the most recent buffered line was injected."""
        back = self.state.buffer_back
        if back is None or not back.is_injected:
            self.log.add(LogKind.WRITE, line)
            if "?" in line:
                with self.lock:
                    self._show_status = True
        with self.lock:
            self.transport.write((line + "\n").encode())
        sleep_ms(wait_ms)

    def read_line(self) -> str | None:
        """The next complete line (without CR/LF), or None if none is available yet."""
        with self.lock:
            self._pending += self.transport.read_available()
            index = 0
            try:
                while index < len(self._pending):
                    byte = self._pending[index]
                    index += 1
                    self.state.reset_idle_time()
                    if byte == 0x0A:
                        line = self._read_buffer.decode("utf-8", "replace")
                        self._read_buffer.clear()
                        front = self.state.buffer_front
                        if front is None or not front.is_injected:
                            if not line.startswith("<"):
                                self.log.add(LogKind.READ, line)
                            elif self._show_status:
                                self.log.add(LogKind.READ, line)
                                self._show_status = False
                        return line
                    if byte != 0x0D:
                        self._read_buffer.append(byte)
                return None
            finally:
                del self._pending[:index]

    def flush_reads(self) -> None:
        """Discards everything received so far."""
        with self.lock:
            self._pending.clear()
            self.transport.read_available()
