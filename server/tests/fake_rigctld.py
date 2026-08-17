"""Loopback-only scripted rigctld server for transport integration tests."""

import asyncio
from collections.abc import Mapping, Sequence


class FakeRigctld:
    def __init__(
        self,
        responses: Mapping[str, Sequence[bytes]],
        *,
        response_delay_s: float = 0.0,
        fragment_gate: asyncio.Event | None = None,
    ) -> None:
        self._responses = dict(responses)
        self._response_delay_s = response_delay_s
        self._fragment_gate = fragment_gate
        self._server: asyncio.AbstractServer | None = None
        self._client_tasks: set[asyncio.Task[None]] = set()
        self._writers: set[asyncio.StreamWriter] = set()
        self.received: list[str] = []
        self.first_fragment_sent = asyncio.Event()
        self.host = "127.0.0.1"
        self.port = 0

    async def __aenter__(self) -> "FakeRigctld":
        self._server = await asyncio.start_server(self._accept, self.host, 0)
        socket = self._server.sockets[0]
        self.port = socket.getsockname()[1]
        return self

    async def __aexit__(self, exc_type, exc, traceback) -> None:
        if self._server is not None:
            self._server.close()
            await self._server.wait_closed()
            self._server = None
        for writer in tuple(self._writers):
            writer.close()
        await asyncio.gather(
            *(writer.wait_closed() for writer in tuple(self._writers)),
            return_exceptions=True,
        )
        for task in tuple(self._client_tasks):
            task.cancel()
        await asyncio.gather(*tuple(self._client_tasks), return_exceptions=True)

    async def _accept(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter
    ) -> None:
        task = asyncio.current_task()
        assert task is not None
        self._client_tasks.add(task)
        self._writers.add(writer)
        try:
            while frame := await reader.readline():
                command_frame = frame.decode("ascii")
                self.received.append(command_frame)
                command = command_frame.removeprefix("|").removesuffix("\n")
                if self._response_delay_s:
                    await asyncio.sleep(self._response_delay_s)
                for index, fragment in enumerate(self._responses.get(command, ())):
                    writer.write(fragment)
                    await writer.drain()
                    if index == 0:
                        self.first_fragment_sent.set()
                        if self._fragment_gate is not None:
                            await self._fragment_gate.wait()
        finally:
            self._writers.discard(writer)
            writer.close()
            await asyncio.gather(writer.wait_closed(), return_exceptions=True)
            self._client_tasks.discard(task)
