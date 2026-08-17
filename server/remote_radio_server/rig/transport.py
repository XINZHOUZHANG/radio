"""Single-connection serialized rigctld transport."""

import asyncio
import itertools

from .errors import RigProtocolError, RigReportError, RigTransportClosed, RigTransportError
from .models import CommandPriority, RigResponse
from .protocol import ExtendedResponseParser, encode_command


class RigctldTransport:
    def __init__(self, host: str = "127.0.0.1", port: int = 4532) -> None:
        if host != "127.0.0.1":
            raise ValueError("RigctldTransport only connects to loopback address 127.0.0.1")
        self._host = host
        self._port = port
        self._queue: asyncio.PriorityQueue[
            tuple[int, int, str, float, asyncio.Future[RigResponse]]
        ] = asyncio.PriorityQueue()
        self._sequence = itertools.count()
        self._reader: asyncio.StreamReader | None = None
        self._writer: asyncio.StreamWriter | None = None
        self._worker: asyncio.Task[None] | None = None
        self._inflight: asyncio.Future[RigResponse] | None = None
        self._closed = False
        self._terminal_error: RigTransportError | RigProtocolError | None = None
        self._lifecycle_lock = asyncio.Lock()

    async def start(self) -> None:
        async with self._lifecycle_lock:
            if self._closed:
                raise RigTransportClosed("rig transport is closed")
            if self._terminal_error is not None:
                raise self._terminal_error
            if self._worker is not None:
                return
            try:
                reader, writer = await asyncio.open_connection(self._host, self._port)
            except (OSError, asyncio.TimeoutError) as error:
                raise RigTransportError("could not connect to rigctld") from error
            if self._closed:
                writer.close()
                await asyncio.gather(writer.wait_closed(), return_exceptions=True)
                raise RigTransportClosed("rig transport is closed")
            self._reader = reader
            self._writer = writer
            self._worker = asyncio.create_task(
                self._run(), name="rigctld-transport-worker"
            )

    async def close(self) -> None:
        async with self._lifecycle_lock:
            if self._closed:
                return
            self._closed = True
            self._fail_pending(RigTransportClosed("rig transport is closed"))
            worker, self._worker = self._worker, None
            writer, self._writer = self._writer, None
            self._reader = None
            if worker is not None:
                worker.cancel()
                await asyncio.gather(worker, return_exceptions=True)
        if writer is not None:
            writer.close()
            await asyncio.gather(writer.wait_closed(), return_exceptions=True)

    async def wait_closed(self) -> None:
        worker = self._worker
        if worker is None:
            if self._terminal_error is not None:
                raise self._terminal_error
            if self._closed:
                return
            raise RigTransportError("rig transport has not been started")
        try:
            await asyncio.shield(worker)
        except asyncio.CancelledError:
            current = asyncio.current_task()
            if current is not None and current.cancelling():
                raise
            if not self._closed:
                raise
        if self._terminal_error is not None:
            raise self._terminal_error

    async def request(
        self,
        command: str,
        priority: CommandPriority = CommandPriority.USER_READ,
        timeout_s: float = 1.5,
    ) -> RigResponse:
        if self._closed:
            raise RigTransportClosed("rig transport is closed")
        if self._terminal_error is not None:
            raise self._terminal_error
        if self._worker is None:
            raise RigTransportError("rig transport has not been started")
        loop = asyncio.get_running_loop()
        future: asyncio.Future[RigResponse] = loop.create_future()
        await self._queue.put((int(priority), next(self._sequence), command, timeout_s, future))
        try:
            return await asyncio.shield(future)
        except asyncio.CancelledError:
            current = asyncio.current_task()
            if current is None or not current.cancelling() or future.cancelled():
                raise
            # The wire exchange is serialized and cannot be abandoned safely: its
            # response must be consumed before another command may use the stream.
            await asyncio.gather(asyncio.shield(future), return_exceptions=True)
            raise

    async def _run(self) -> None:
        while True:
            _, _, command, timeout_s, future = await self._queue.get()
            if future.cancelled():
                continue
            self._inflight = future
            try:
                response = await asyncio.wait_for(self._exchange(command), timeout_s)
                if response.report != 0:
                    raise RigReportError(response.report)
            except asyncio.TimeoutError as error:
                transport_error = RigTransportError("rigctld response timed out")
                self._set_exception(future, transport_error)
                await self._abort_connection(transport_error)
                return
            except RigProtocolError as error:
                self._set_exception(future, error)
                await self._abort_connection(error)
                return
            except (OSError, ConnectionError, asyncio.IncompleteReadError) as error:
                transport_error = RigTransportError("rigctld connection failed")
                self._set_exception(future, transport_error)
                await self._abort_connection(transport_error)
                return
            except asyncio.CancelledError:
                raise
            except Exception as error:
                self._set_exception(future, error)
            else:
                self._set_result(future, response)
            finally:
                self._inflight = None

    async def _exchange(self, command: str) -> RigResponse:
        reader = self._reader
        writer = self._writer
        if reader is None or writer is None:
            raise RigTransportClosed("rig transport is closed")
        writer.write(encode_command(command))
        await writer.drain()
        parser = ExtendedResponseParser()
        while True:
            chunk = await reader.read(4096)
            if not chunk:
                raise ConnectionError("rigctld closed the connection")
            responses = parser.feed(chunk)
            if len(responses) > 1:
                raise RigProtocolError("received more than one response for a request")
            if responses:
                response = responses[0]
                expected_verb = command.lstrip("\\").split(maxsplit=1)[0].casefold()
                if response.command.casefold() != expected_verb:
                    raise RigProtocolError(
                        "response command does not match request command"
                    )
                if parser.has_trailing_data:
                    raise RigProtocolError("response contains trailing data")
                return response

    async def _abort_connection(
        self, error: RigTransportError | RigProtocolError
    ) -> None:
        self._terminal_error = error
        self._fail_pending(error)
        writer, self._writer = self._writer, None
        self._reader = None
        if writer is not None:
            writer.close()
            await asyncio.gather(writer.wait_closed(), return_exceptions=True)

    def _fail_pending(self, error: Exception) -> None:
        self._set_exception(self._inflight, error)
        while True:
            try:
                _, _, _, _, future = self._queue.get_nowait()
            except asyncio.QueueEmpty:
                return
            self._set_exception(future, error)

    @staticmethod
    def _set_result(future: asyncio.Future[RigResponse] | None, value: RigResponse) -> None:
        if future is not None and not future.done():
            future.set_result(value)

    @staticmethod
    def _set_exception(future: asyncio.Future[RigResponse] | None, error: Exception) -> None:
        if future is not None and not future.done():
            future.set_exception(error)
