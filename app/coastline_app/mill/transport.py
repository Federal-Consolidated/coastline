"""Raw byte transport to the mill, the real serial port and the device finder.
Port of Serial/*.swift. Uses pyserial, so the same code runs on Windows (COM ports) and macOS."""

from __future__ import annotations

import sys
import threading
from dataclasses import dataclass
from typing import Protocol

from .errors import MillError, MillErrorKind as K


class SerialTransport(Protocol):
    """Implemented by `SerialPort` for real hardware and by `MockGRBL` for tests and the
    app's simulated-mill mode."""

    def open(self) -> None: ...
    def close(self) -> None: ...
    def write(self, data: bytes) -> None: ...  # all bytes or MillError(FAILED_WRITE)
    def read_available(self) -> bytes: ...  # never blocks
    @property
    def is_open(self) -> bool: ...


@dataclass(frozen=True)
class MillDevice:
    """A USB serial device that looks like a supported mill."""

    path: str
    serial_number: str
    usb_id: str = ""  # `2341:0043` (empty when not known), for diagnostics

    @property
    def id(self) -> str:
        return self.path + "#" + self.serial_number

    @property
    def diagnostics(self) -> str:
        """One line for the console: where it is, which USB device and its serial number."""
        serial = " · no serial number" if not self.serial_number or self.serial_number == self.path else f" · serial {self.serial_number}"
        return self.path + (f" · USB {self.usb_id}" if self.usb_id else "") + serial

    @property
    def label(self) -> str:
        return self.path.replace("/dev/", "")


class SerialPort:
    """A serial port read by a background thread into a byte queue; writes are synchronous.
    Exclusive access, so a second opener cannot steal bytes."""

    def __init__(self, path: str, baud_rate: int = 115_200) -> None:
        self.path = path
        self.baud_rate = baud_rate
        self._lock = threading.Lock()
        self._port = None
        self._received = bytearray()
        self._reader: threading.Thread | None = None

    @property
    def is_open(self) -> bool:
        with self._lock:
            return self._port is not None

    def open(self) -> None:
        import serial  # pyserial

        self.close()
        last: Exception | None = None
        for _ in range(20):  # the previous owner's handle may still be closing
            try:
                kwargs = {"exclusive": True} if sys.platform != "win32" else {}  # Windows ports are always exclusive
                port = serial.Serial(self.path, self.baud_rate, bytesize=8, parity="N", stopbits=1,
                                     timeout=0.05, write_timeout=5, rtscts=False, dsrdtr=False, **kwargs)
                break
            except (serial.SerialException, OSError) as e:
                last = e
                import time
                time.sleep(0.05)
        else:
            raise MillError(K.FAILED_OPEN, f"failed to open - {self.path}" + (f" ({last})" if last else "") + _open_hint(last))
        with self._lock:
            self._port = port
            self._received.clear()
        self._reader = threading.Thread(target=self._read_loop, args=(port,), name="serial-read", daemon=True)
        self._reader.start()

    def close(self) -> None:
        with self._lock:
            port, self._port = self._port, None
            self._received.clear()
        if port is not None:
            try:
                port.close()
            except Exception:  # noqa: BLE001
                pass

    def write(self, data: bytes) -> None:
        with self._lock:
            port = self._port
            if port is None:
                raise MillError(K.FAILED_WRITE)
            try:
                port.write(bytes(data))
            except Exception as e:  # noqa: BLE001
                raise MillError(K.FAILED_WRITE, str(e)) from None

    def read_available(self) -> bytes:
        with self._lock:
            data = bytes(self._received)
            self._received.clear()
            return data

    def set_modem_lines(self, dtr: bool, rts: bool) -> None:
        """Sets or clears DTR/RTS (used to reset the board before flashing firmware)."""
        with self._lock:
            port = self._port
        if port is not None:
            port.dtr, port.rts = dtr, rts

    def discard_input(self) -> None:
        with self._lock:
            port = self._port
        if port is not None:
            try:
                port.reset_input_buffer()
            except Exception:  # noqa: BLE001
                pass
        self.read_available()

    def _read_loop(self, port) -> None:
        while True:
            with self._lock:
                if self._port is not port:
                    return
            try:
                chunk = port.read(max(1, port.in_waiting or 1))
            except Exception:  # noqa: BLE001 — unplugged: stop; writes now fail with FAILED_WRITE
                with self._lock:
                    if self._port is port:
                        self._port = None
                try:
                    port.close()
                except Exception:  # noqa: BLE001
                    pass
                return
            if chunk:
                with self._lock:
                    if self._port is port:
                        self._received += chunk


def _open_hint(error: Exception | None) -> str:
    """What to do when the port was found but would not open."""
    text = str(error or "").lower()
    if "permission" in text or "access is denied" in text or "busy" in text or "in use" in text:
        if sys.platform.startswith("linux"):
            return (". The port was found but Coastline may not open it: add yourself to the dialout group "
                    "(sudo usermod -aG dialout $USER), then log out and in.")
        return ". The port was found but is in use: close any other program talking to the mill (another sender, Arduino IDE)."
    return ""


class PortFinder:
    """Finds plugged-in mills: the mill's Arduino boards (2341:0043 and 2341:003E,
    both verified) and CH340 USB serial adapters (1A86:7523). A serial number is not required."""

    ACCEPTED_IDS = {(0x2341, 0x0043), (0x2341, 0x003E), (0x1A86, 0x7523)}

    @staticmethod
    def available_mills() -> list[MillDevice]:
        try:
            from serial.tools import list_ports
        except ImportError:
            return []
        mills = []
        for p in list_ports.comports():
            if (p.vid, p.pid) not in PortFinder.ACCEPTED_IDS:
                continue
            device = p.device
            if sys.platform == "darwin":
                # macOS lists both tty.* and cu.*; the call-out device is the one to open.
                if device.startswith("/dev/tty."):
                    device = "/dev/cu." + device[len("/dev/tty."):]
            # CH340 clones often report no serial number; fall back to the port's location.
            serial_number = p.serial_number or p.location or device
            mills.append(MillDevice(device, serial_number, "%04X:%04X" % (p.vid, p.pid)))
        unique = {m.path: m for m in mills}
        return sorted(unique.values(), key=lambda m: m.path)
