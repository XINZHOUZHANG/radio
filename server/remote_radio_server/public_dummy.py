"""Lifecycle owner for the explicit public Hamlib Dummy acceptance stack."""

from __future__ import annotations

import asyncio
import secrets
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path

from .rig.launcher import RigctldConfig, RigctldLauncher
from .runtime import ControlPlaneRuntime
from .server import RemoteRadioServer
from .static_http import StaticWebServer


@dataclass(frozen=True, slots=True)
class PublicDummyConfig:
    web_root: Path
    http_port: int = 8080
    websocket_port: int = 8765
    rigctld_port: int = 4532


@dataclass(frozen=True, slots=True)
class PublicDummyStartup:
    url: str
    websocket_url: str
    http_port: int
    websocket_port: int
    rigctld_port: int
    device_id: str
    token: str
    identity: Mapping[str, object]


def _default_runtime(config: PublicDummyConfig) -> ControlPlaneRuntime:
    rig_config = RigctldConfig(
        model_id=1,
        device=None,
        host="0.0.0.0",
        port=config.rigctld_port,
        hardware_tx_enabled=False,
        public_dummy_test=True,
    )
    return ControlPlaneRuntime(
        host="127.0.0.1",
        port=config.rigctld_port,
        launcher=RigctldLauncher(rig_config),
        hardware_tx_enabled=False,
    )


class PublicDummyStack:
    def __init__(
        self,
        config: PublicDummyConfig,
        *,
        runtime_factory=None,
        websocket_factory=None,
        http_factory=None,
        token_factory=None,
    ) -> None:
        if not isinstance(config, PublicDummyConfig):
            raise TypeError("config must be a PublicDummyConfig")
        self._config = config
        self._runtime_factory = runtime_factory or _default_runtime
        self._websocket_factory = websocket_factory or RemoteRadioServer
        self._http_factory = http_factory or StaticWebServer
        self._token_factory = token_factory or (lambda: secrets.token_urlsafe(32))
        self._runtime = None
        self._websocket_server = None
        self._http_server = None
        self._startup: PublicDummyStartup | None = None
        self._closed = False
        self._close_complete = False
        self._lifecycle_lock = asyncio.Lock()

    async def start(self) -> PublicDummyStartup:
        try:
            async with self._lifecycle_lock:
                if self._closed:
                    raise RuntimeError("public Dummy stack is closed")
                if self._startup is not None:
                    return self._startup

                runtime = self._runtime_factory(self._config)
                self._runtime = runtime
                await runtime.start()
                capabilities = await runtime.gateway.initial_event()
                identity = _require_dummy_identity(capabilities)

                token = self._token_factory()
                if not isinstance(token, str) or not token:
                    raise ValueError("public Dummy token must be non-empty text")
                device_id = "web-test"

                websocket_server = self._websocket_factory(
                    runtime.gateway, {device_id: token}
                )
                await websocket_server.serve(
                    host="0.0.0.0",
                    port=self._config.websocket_port,
                    allow_non_loopback=True,
                )
                self._websocket_server = websocket_server

                http_server = self._http_factory(
                    self._config.web_root, allow_non_loopback=True
                )
                await http_server.serve(
                    host="0.0.0.0", port=self._config.http_port
                )
                self._http_server = http_server

                http_port = http_server.port
                websocket_port = websocket_server.port
                startup = PublicDummyStartup(
                    url=f"http://0.0.0.0:{http_port}",
                    websocket_url=f"ws://0.0.0.0:{websocket_port}/radio",
                    http_port=http_port,
                    websocket_port=websocket_port,
                    rigctld_port=self._config.rigctld_port,
                    device_id=device_id,
                    token=token,
                    identity=dict(identity),
                )
                self._startup = startup
                return startup
        except BaseException:
            await self.close()
            raise

    async def close(self) -> None:
        async with self._lifecycle_lock:
            if self._close_complete:
                return
            self._closed = True
            cleanup = asyncio.create_task(
                self._close_owned_resources(), name="public-dummy-cleanup"
            )
            try:
                await asyncio.shield(cleanup)
            except asyncio.CancelledError as cancellation:
                result = (await asyncio.gather(cleanup, return_exceptions=True))[0]
                self._close_complete = self._all_resources_closed()
                if isinstance(result, BaseException):
                    raise BaseExceptionGroup(
                        "public Dummy cleanup was cancelled and failed",
                        [cancellation, result],
                    )
                raise
            except BaseException:
                self._close_complete = self._all_resources_closed()
                raise
            self._close_complete = True

    async def _close_owned_resources(self) -> None:
        failures = []

        async def close_resource(attribute: str) -> None:
            resource = getattr(self, attribute)
            if resource is None:
                return
            try:
                await resource.close()
            except BaseException as error:
                failures.append(error)
            else:
                setattr(self, attribute, None)

        await close_resource("_http_server")
        await close_resource("_websocket_server")
        await close_resource("_runtime")
        if len(failures) == 1:
            raise failures[0]
        if failures:
            raise BaseExceptionGroup("public Dummy cleanup failed", failures)

    def _all_resources_closed(self) -> bool:
        return (
            self._http_server is None
            and self._websocket_server is None
            and self._runtime is None
        )


def _require_dummy_identity(capabilities) -> Mapping[str, object]:
    if not isinstance(capabilities, Mapping):
        raise ValueError("public Dummy mode requires official Hamlib model 1")
    identity = capabilities.get("identity")
    if not isinstance(identity, Mapping):
        raise ValueError("public Dummy mode requires official Hamlib model 1")
    model_id = identity.get("model_id")
    if type(model_id) is not int or model_id != 1:
        raise ValueError("public Dummy mode requires official Hamlib model 1")
    return identity


__all__ = ["PublicDummyConfig", "PublicDummyStack", "PublicDummyStartup"]
