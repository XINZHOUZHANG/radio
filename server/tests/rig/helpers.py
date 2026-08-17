import asyncio
import inspect
from collections import deque
from dataclasses import dataclass
from pathlib import Path

from remote_radio_server.rig.models import RigCapabilities, RigIdentity, RigResponse
from remote_radio_server.rig.protocol import ExtendedResponseParser
from remote_radio_server.rig.commands import RigCommandService
from remote_radio_server.rig.state import RigStateService, RigStateStore


def response(command: str, **fields: str) -> RigResponse:
    report = int(fields.pop("report", "0"))
    return RigResponse(command, tuple(fields.items()), report)


def ok(command: str) -> RigResponse:
    return response(command)


def value(command: str, **fields: str) -> RigResponse:
    return response(command, **fields)


def fixture_response(name: str) -> RigResponse:
    fixture = Path(__file__).parents[1] / "fixtures" / name
    responses = ExtendedResponseParser().feed(fixture.read_bytes())
    if len(responses) != 1:
        raise AssertionError(f"fixture {name} must contain exactly one response")
    return responses[0]


class ScriptedTransport:
    def __init__(self, responses=()):
        self.responses = (
            {command: deque(items if isinstance(items, (list, tuple, deque)) else (items,))
             for command, items in responses.items()}
            if isinstance(responses, dict)
            else deque(responses)
        )
        self.requests = []

    @property
    def commands(self):
        return [command for command, _, _ in self.requests]

    async def request(self, command, *args, **kwargs):
        self.requests.append((command, args, kwargs))
        if isinstance(self.responses, dict):
            if command not in self.responses:
                raise AssertionError(f"unexpected scripted command: {command}")
            if not self.responses[command]:
                raise AssertionError(f"scripted command exhausted: {command}")
            result = self.responses[command].popleft()
        else:
            if not self.responses:
                raise AssertionError("scripted transport has no response")
            result = self.responses[0]
            if isinstance(result, RigResponse):
                expected_command = result.command
                matches = _command_verb(expected_command) == _command_verb(command)
            elif isinstance(result, tuple) and len(result) == 2 and isinstance(result[0], str):
                expected_command, result = result
                matches = _normalized_command(expected_command) == _normalized_command(command)
            else:
                raise AssertionError(
                    "ordered scripted transport must label exception results with (command, result)"
                )
            if not matches:
                raise AssertionError(
                    f"ordered scripted command expected {_command_verb(expected_command)}, "
                    f"got {_command_verb(command)}"
                )
            self.responses.popleft()
        if isinstance(result, BaseException):
            raise result
        if inspect.isawaitable(result):
            result = await result
        return result


@dataclass
class FakeClock:
    now: float = 0.0

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds


class DeterministicSleep:
    def __init__(self) -> None:
        self.block = False
        self.calls = []
        self._waiters = deque()

    async def __call__(self, seconds: float) -> None:
        self.calls.append(seconds)
        if not self.block:
            await asyncio.sleep(0)
            return
        future = asyncio.get_running_loop().create_future()
        self._waiters.append(future)
        await future

    async def wait_until_blocked(self) -> None:
        while not self._waiters:
            await asyncio.sleep(0)

    def release_next(self) -> None:
        self._waiters.popleft().set_result(None)


class DeferredResponse:
    def __init__(self, result) -> None:
        self.result = result
        self.started = asyncio.Event()
        self.released = asyncio.Event()

    def __await__(self):
        return self._wait().__await__()

    async def _wait(self):
        self.started.set()
        await self.released.wait()
        return self.result


class RecordingPtt:
    def __init__(self):
        self.calls = []

    async def set_ptt(self, enabled: bool):
        self.calls.append(enabled)


class StateServiceTransport:
    def __init__(self, readable_levels: set[str]) -> None:
        defaults = {
            "\\get_freq": response("get_freq", Frequency="14074000"),
            "\\get_mode": response("get_mode", Mode="USB", Passband="2400"),
            "\\get_vfo": response("get_vfo", VFO="VFOA"),
            "\\get_ptt": response("get_ptt", PTT="1"),
            **{
                f"\\get_level {level}": RigResponse("get_level", (), 0, ("1.5",))
                for level in readable_levels
            },
        }
        self.responses = {command: deque((result,)) for command, result in defaults.items()}
        self.commands = []
        self.requests = []

    async def request(self, command, *args, **kwargs):
        self.commands.append(command)
        self.requests.append((command, args, kwargs))
        if command not in self.responses:
            raise AssertionError(f"unexpected scripted command: {command}")
        results = self.responses[command]
        if not results:
            raise AssertionError(f"scripted command exhausted: {command}")
        result = results.popleft() if len(results) > 1 else results[0]
        if isinstance(result, BaseException):
            raise result
        return result


@dataclass
class StateServiceHarness:
    service: RigStateService
    transport: StateServiceTransport
    store: RigStateStore
    clock: FakeClock

    async def poll_once(self, transmitting: bool):
        return await self.service.poll_once(transmitting)

    async def full_refresh(self, transmitting: bool = False):
        return await self.service.full_refresh(transmitting)


def make_state_service(
    readable_levels: set[str], *, supports_ptt_read: bool = False
) -> StateServiceHarness:
    transport = StateServiceTransport(readable_levels)
    store = RigStateStore()
    clock = FakeClock()
    capabilities = RigCapabilities(
        identity=RigIdentity("Test", "Rig", None, None, None),
        readable_levels=frozenset(readable_levels),
        supports_ptt_read=supports_ptt_read,
    )
    return StateServiceHarness(
        RigStateService(transport, capabilities, store=store, clock=clock),
        transport,
        store,
        clock,
    )


@dataclass
class CommandServiceHarness:
    service: RigCommandService
    transport: ScriptedTransport
    store: RigStateStore
    sleep: DeterministicSleep
    audit_events: list
    audit_transport_counts: list

    def __getattr__(self, name):
        return getattr(self.service, name)


def make_command_service(
    *, tx_ranges=(), script=(), rig_identity=("Test", "Rig")
) -> CommandServiceHarness:
    transport = ScriptedTransport(script)
    store = RigStateStore()
    sleep = DeterministicSleep()
    audit_events = []
    audit_transport_counts = []

    def audit_sink(event_name, metadata):
        audit_transport_counts.append(len(transport.commands))
        audit_events.append((event_name, metadata))

    capabilities = RigCapabilities(
        identity=RigIdentity(*rig_identity, None, None, None),
        vfos=frozenset({"VFOA", "VFOB"}),
        modes=frozenset({"USB", "LSB"}),
        readable_levels=frozenset({"AF"}),
        writable_levels=frozenset({"AF"}),
        readable_functions=frozenset({"NB"}),
        writable_functions=frozenset({"NB"}),
        rx_ranges_hz=((100_000, 60_000_000),),
        tx_ranges_hz=tuple(tx_ranges),
        supports_split_read=True,
        supports_split_write=True,
    )
    return CommandServiceHarness(
        RigCommandService(
            transport,
            capabilities,
            store=store,
            sleep=sleep,
            audit_sink=audit_sink,
        ),
        transport,
        store,
        sleep,
        audit_events,
        audit_transport_counts,
    )


def identity(manufacturer: str, model: str) -> RigIdentity:
    return RigIdentity(manufacturer, model, None, None, None)


def _normalized_command(command: str) -> str:
    return command.strip().lstrip("\\")


def _command_verb(command: str) -> str:
    return _normalized_command(command).split(maxsplit=1)[0]
