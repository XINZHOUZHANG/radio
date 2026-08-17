"""Loopback-only in-process rigctld endpoint for acceptance and development."""

from __future__ import annotations

import asyncio
import math
import re


class MockRigctld:
    def __init__(self, *, port: int = 0) -> None:
        if type(port) is not int or not 0 <= port <= 65535:
            raise ValueError("port must be in the range 0..65535")
        self.host = "127.0.0.1"
        self.port = port
        self.frequency_hz = 14_074_000
        self.mode = "USB"
        self.passband_hz = 2400
        self.vfo = "VFOA"
        self.ptt = False
        self.levels = {"AF": 0.25, "SWR": 1.1, "ALC": 0.0}
        self.functions = {"NB": False}
        self.split_enabled = False
        self.split_vfo = "VFOB"
        self.split_frequency_hz = 14_074_000
        self.split_mode = "USB"
        self.split_passband_hz = 2400
        self.commands: list[str] = []
        self._server: asyncio.AbstractServer | None = None
        self._writers: set[asyncio.StreamWriter] = set()
        self._client_tasks: set[asyncio.Task[None]] = set()
        self._close_lock = asyncio.Lock()
        self._closed = False

    async def __aenter__(self) -> "MockRigctld":
        await self.start()
        return self

    async def __aexit__(self, exc_type, exc, traceback) -> None:
        await self.close()

    async def start(self) -> None:
        if self._closed:
            raise RuntimeError("mock rigctld is closed")
        if self._server is not None:
            return
        self._server = await asyncio.start_server(self._accept, self.host, self.port)
        self.port = self._server.sockets[0].getsockname()[1]

    async def close(self) -> None:
        async with self._close_lock:
            if self._closed:
                return
            self._closed = True
            server, self._server = self._server, None
            if server is not None:
                server.close()
            writers = tuple(self._writers)
            for writer in writers:
                writer.transport.abort()
            current = asyncio.current_task()
            tasks = tuple(task for task in self._client_tasks if task is not current)
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            if server is not None:
                await server.wait_closed()
            self._writers.clear()
            self._client_tasks.clear()

    async def disconnect_clients(self) -> None:
        writers = tuple(self._writers)
        for writer in writers:
            writer.close()
        await asyncio.gather(
            *(writer.wait_closed() for writer in writers), return_exceptions=True
        )

    async def _accept(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter
    ) -> None:
        task = asyncio.current_task()
        assert task is not None
        self._client_tasks.add(task)
        self._writers.add(writer)
        try:
            while frame := await reader.readline():
                response = self._handle_frame(frame)
                writer.write(response)
                await writer.drain()
        except (ConnectionError, asyncio.IncompleteReadError):
            pass
        finally:
            self._writers.discard(writer)
            writer.close()
            self._client_tasks.discard(task)

    def _handle_frame(self, frame: bytes) -> bytes:
        try:
            text = frame.decode("ascii")
        except UnicodeDecodeError:
            return _response("invalid", report=-1)
        if not text.startswith("|") or not text.endswith("\n") or "\r" in text:
            return _response("invalid", report=-1)
        command = text[1:-1]
        self.commands.append(command)
        try:
            return self._dispatch(command)
        except (ValueError, OverflowError):
            return _response(_verb(command), report=-1)

    def _dispatch(self, command: str) -> bytes:
        verb, _, arguments = command.partition(" ")
        name = verb.removeprefix("\\")
        if command == "\\hamlib_version":
            return _response(name, fields=(("Version", "4.6-mock"),))
        if command == "\\dump_caps":
            return _response(
                name,
                fields=(
                    ("Caps dump for model", "1"),
                    ("Mfg name", "Mock"),
                    ("Model name", "In-Process Rig"),
                    ("Model ID", "1"),
                    ("Backend version", "1.0"),
                    ("Mode list", "USB LSB CW"),
                    ("VFO list", "VFOA VFOB"),
                    ("Get PTT", "yes"),
                    ("Set PTT", "yes"),
                    ("Can get split VFO", "yes"),
                    ("Can get split freq", "yes"),
                    ("Can get split mode", "yes"),
                    ("Can set split VFO", "yes"),
                    ("Can set split freq", "yes"),
                    ("Can set split mode", "yes"),
                    ("RX range", "100000 60000000"),
                    ("TX range", "14000000 14350000"),
                    ("Filters", "USB 2400 LSB 2400 CW 500"),
                ),
            )
        if command == "\\get_mode ?":
            return _response(name, fields=(("Mode", self.mode),))
        if command == "\\get_level ?":
            return _response(name, fields=(("Level", "AF SWR ALC"),))
        if command == "\\set_level ?":
            return _response(name, fields=(("Level", "AF"),))
        if command == "\\get_func ?":
            return _response(name, fields=(("Func", "NB"),))
        if command == "\\set_func ?":
            return _response(name, fields=(("Func", "NB"),))
        if command == "\\get_freq":
            return _response(name, fields=(("Frequency", str(self.frequency_hz)),))
        if name == "set_freq":
            self.frequency_hz = _integer(arguments)
            return _response(name)
        if command == "\\get_mode":
            return _response(
                name,
                fields=(("Mode", self.mode), ("Passband", str(self.passband_hz))),
            )
        if name == "set_mode":
            mode, passband = _two_tokens(arguments)
            if mode not in {"USB", "LSB", "CW"}:
                return _response(name, report=-1)
            parsed_passband = _integer(passband)
            if parsed_passband < 0:
                return _response(name, report=-1)
            self.mode = mode
            if parsed_passband:
                self.passband_hz = parsed_passband
            return _response(name)
        if command == "\\get_vfo":
            return _response(name, fields=(("VFO", self.vfo),))
        if name == "set_vfo":
            if arguments not in {"VFOA", "VFOB"}:
                return _response(name, report=-1)
            self.vfo = arguments
            return _response(name)
        if command == "\\get_ptt":
            return _response(name, fields=(("PTT", str(int(self.ptt))),))
        if name == "set_ptt":
            self.ptt = _boolean(arguments)
            return _response(name)
        if name in {"get_level", "set_level"}:
            return self._level(name, arguments)
        if name in {"get_func", "set_func"}:
            return self._function(name, arguments)
        if command == "\\get_split_vfo":
            return _response(
                name,
                fields=(
                    ("Split", str(int(self.split_enabled))),
                    ("TX VFO", self.split_vfo),
                ),
            )
        if name == "set_split_vfo":
            enabled, vfo = _two_tokens(arguments)
            if vfo not in {"VFOA", "VFOB"}:
                return _response(name, report=-1)
            self.split_enabled = _boolean(enabled)
            self.split_vfo = vfo
            return _response(name)
        if command == "\\get_split_freq":
            return _response(
                name, fields=(("TX Frequency", str(self.split_frequency_hz)),)
            )
        if name == "set_split_freq":
            self.split_frequency_hz = _integer(arguments)
            return _response(name)
        if command == "\\get_split_mode":
            return _response(
                name,
                fields=(
                    ("TX Mode", self.split_mode),
                    ("TX Passband", str(self.split_passband_hz)),
                ),
            )
        if name == "set_split_mode":
            mode, passband = _two_tokens(arguments)
            if mode not in {"USB", "LSB", "CW"}:
                return _response(name, report=-1)
            parsed_passband = _integer(passband)
            if parsed_passband < 0:
                return _response(name, report=-1)
            self.split_mode = mode
            if parsed_passband:
                self.split_passband_hz = parsed_passband
            return _response(name)
        if name == "send_raw" and arguments == "; ID":
            return _response(name)
        return _response(name or "invalid", report=-4)

    def _level(self, name: str, arguments: str) -> bytes:
        if name == "get_level":
            if arguments not in self.levels:
                return _response(name, report=-4)
            return _response(name, values=(_number(self.levels[arguments]),))
        level, raw_value = _two_tokens(arguments)
        if level != "AF":
            return _response(name, report=-4)
        value = float(raw_value)
        if not math.isfinite(value):
            return _response(name, report=-1)
        self.levels[level] = value
        return _response(name)

    def _function(self, name: str, arguments: str) -> bytes:
        if name == "get_func":
            if arguments not in self.functions:
                return _response(name, report=-4)
            return _response(name, values=(str(int(self.functions[arguments])),))
        function, raw_enabled = _two_tokens(arguments)
        if function != "NB":
            return _response(name, report=-4)
        self.functions[function] = _boolean(raw_enabled)
        return _response(name)


def _response(
    command: str,
    *,
    fields: tuple[tuple[str, str], ...] = (),
    values: tuple[str, ...] = (),
    report: int = 0,
) -> bytes:
    safe_command = command if re.fullmatch(r"[a-z][a-z0-9_]*", command) else "invalid"
    records = [f"{safe_command}:"]
    records.extend(f"{key}: {value}" for key, value in fields)
    records.extend(values)
    records.append(f"RPRT {report}")
    return ("|".join(records) + "|\n").encode("ascii")


def _verb(command: str) -> str:
    return command.partition(" ")[0].removeprefix("\\") or "invalid"


def _two_tokens(arguments: str) -> tuple[str, str]:
    parts = arguments.split()
    if len(parts) != 2:
        raise ValueError
    return parts[0], parts[1]


def _integer(value: str) -> int:
    if not re.fullmatch(r"-?\d+", value):
        raise ValueError
    return int(value)


def _boolean(value: str) -> bool:
    if value not in {"0", "1"}:
        raise ValueError
    return value == "1"


def _number(value: float) -> str:
    return format(value, "g")


__all__ = ["MockRigctld"]
