"""Safe optional lifecycle management for a local rigctld process."""

import asyncio
from dataclasses import dataclass
from math import isfinite


@dataclass(frozen=True, slots=True)
class RigctldConfig:
    model_id: int
    device: str
    baud: int | None = None
    host: str = "127.0.0.1"
    port: int = 4532
    hardware_tx_enabled: bool = False


def build_rigctld_args(config: RigctldConfig) -> list[str]:
    if not isinstance(config, RigctldConfig):
        raise TypeError("config must be a RigctldConfig")
    _positive_integer(config.model_id, "model_id")
    if not isinstance(config.device, str):
        raise TypeError("device must be text")
    if not config.device.strip():
        raise ValueError("device must be non-empty text")
    if any(character in config.device for character in "\r\n\0"):
        raise ValueError("device contains a prohibited control character")
    if config.baud is not None:
        _positive_integer(config.baud, "baud")
    if config.host != "127.0.0.1":
        raise ValueError("rigctld host must be exactly 127.0.0.1")
    _positive_integer(config.port, "port")
    if config.port > 65535:
        raise ValueError("port must be in the range 1..65535")
    if type(config.hardware_tx_enabled) is not bool:
        raise TypeError("hardware_tx_enabled must be a boolean")

    args = ["rigctld", "-m", str(config.model_id), "-r", config.device]
    if config.baud is not None:
        args.extend(("-s", str(config.baud)))
    args.extend(("-T", config.host, "-t", str(config.port)))
    return args


def _positive_integer(value: object, field: str) -> None:
    if type(value) is not int:
        raise TypeError(f"{field} must be an integer")
    if value <= 0:
        raise ValueError(f"{field} must be positive")


class RigctldLauncher:
    def __init__(
        self,
        config: RigctldConfig,
        *,
        process_factory=None,
        terminate_timeout_s: float = 2.0,
    ) -> None:
        self._config = config
        self._args = build_rigctld_args(config)
        self._process_factory = process_factory or asyncio.create_subprocess_exec
        if (
            isinstance(terminate_timeout_s, bool)
            or not isinstance(terminate_timeout_s, (int, float))
            or not isfinite(terminate_timeout_s)
            or terminate_timeout_s <= 0
        ):
            raise ValueError("terminate_timeout_s must be positive")
        self._terminate_timeout_s = float(terminate_timeout_s)
        self._process = None
        self._closed = False
        self._lifecycle_lock = asyncio.Lock()

    @property
    def config(self) -> RigctldConfig:
        return self._config

    @property
    def hardware_tx_enabled(self) -> bool:
        return self._config.hardware_tx_enabled

    @property
    def process(self):
        return self._process

    async def start(self) -> None:
        async with self._lifecycle_lock:
            if self._closed:
                raise RuntimeError("rigctld launcher is closed")
            if self._process is not None:
                return
            self._process = await self._process_factory(*self._args)

    async def close(self) -> None:
        async with self._lifecycle_lock:
            self._closed = True
            process = self._process
            if process is None:
                return
            if process.returncode is not None:
                self._process = None
                return
            cleanup = asyncio.create_task(
                self._stop_process(process), name="rigctld-launcher-cleanup"
            )
            try:
                await asyncio.shield(cleanup)
            except asyncio.CancelledError:
                result = (await asyncio.gather(cleanup, return_exceptions=True))[0]
                if not isinstance(result, BaseException) or process.returncode is not None:
                    self._process = None
                raise
            else:
                self._process = None

    async def _stop_process(self, process) -> None:
        process.terminate()
        try:
            await asyncio.wait_for(
                process.wait(), timeout=self._terminate_timeout_s
            )
        except asyncio.TimeoutError:
            process.kill()
            await asyncio.wait_for(
                process.wait(), timeout=self._terminate_timeout_s
            )
