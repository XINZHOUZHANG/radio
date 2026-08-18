"""Command-line entry point for the Hamlib control plane."""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
from pathlib import Path

from .gateway import GatewayError, Principal, serialize_json_event, serialize_snapshot
from .public_dummy import PublicDummyConfig, PublicDummyStack, PublicDummyStartup
from .rig.launcher import RigctldConfig, RigctldLauncher
from .runtime import ControlPlaneRuntime
from .server import RemoteRadioServer


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="python -m remote_radio_server")
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--mock", action="store_true", help="use the in-process mock")
    source.add_argument(
        "--launch-rigctld", action="store_true", help="launch a local rigctld"
    )
    source.add_argument(
        "--public-dummy-test",
        action="store_true",
        help="serve the explicit public official-Dummy acceptance stack",
    )
    parser.add_argument("--once", action="store_true", help="print initial state and exit")
    parser.add_argument(
        "--serve", action="store_true", help="serve loopback WebSocket clients"
    )
    parser.add_argument("--host", default="127.0.0.1", help="WebSocket listen host")
    parser.add_argument("--port", type=int, default=8765, help="WebSocket listen port")
    parser.add_argument("--http-port", type=int, default=8080, help="dashboard HTTP port")
    parser.add_argument(
        "--device-token",
        action="append",
        default=[],
        metavar="DEVICE=TOKEN",
        help="authorize a WebSocket device (repeatable)",
    )
    parser.add_argument("--rigctld-host", default="127.0.0.1")
    parser.add_argument("--rigctld-port", type=int, default=4532)
    parser.add_argument("--model-id", type=int)
    parser.add_argument("--device")
    parser.add_argument("--baud", type=int)
    parser.add_argument("--enable-hardware-tx", action="store_true")
    parser.add_argument("--acknowledge-transmit-risk", action="store_true")
    return parser


def _validated_args(argv=None):
    parser = _parser()
    args = parser.parse_args(argv)
    if args.rigctld_host != "127.0.0.1":
        parser.error("--rigctld-host must be exactly 127.0.0.1")
    if not 1 <= args.rigctld_port <= 65535:
        parser.error("--rigctld-port must be in the range 1..65535")
    if not 1 <= args.http_port <= 65535:
        parser.error("--http-port must be in the range 1..65535")
    if args.enable_hardware_tx != args.acknowledge_transmit_risk:
        parser.error(
            "--enable-hardware-tx and --acknowledge-transmit-risk must be supplied together"
        )
    if args.serve and args.once:
        parser.error("--serve is incompatible with --once")
    if args.host != "127.0.0.1":
        parser.error("--host must be exactly 127.0.0.1")
    if not 1 <= args.port <= 65535:
        parser.error("--port must be in the range 1..65535")
    if args.public_dummy_test:
        if args.serve or args.once:
            parser.error("--public-dummy-test is incompatible with --serve and --once")
        if args.device_token:
            parser.error("--public-dummy-test does not accept --device-token")
        if any(value is not None for value in (args.model_id, args.device, args.baud)):
            parser.error(
                "--public-dummy-test does not accept model, device, or baud options"
            )
        if args.enable_hardware_tx or args.acknowledge_transmit_risk:
            parser.error("--public-dummy-test forbids hardware TX flags")
        args.device_tokens = {}
        return args
    if args.launch_rigctld and (args.model_id is None or args.device is None):
        parser.error("--launch-rigctld requires --model-id and --device")
    if not args.launch_rigctld and any(
        value is not None for value in (args.model_id, args.device, args.baud)
    ):
        parser.error("--model-id, --device, and --baud require --launch-rigctld")
    if args.http_port != 8080:
        parser.error("--http-port requires --public-dummy-test")
    device_tokens = {}
    for entry in args.device_token:
        if "=" not in entry:
            parser.error("--device-token must use DEVICE=TOKEN")
        device_id, token = entry.split("=", 1)
        if not device_id.strip() or not token.strip():
            parser.error("--device-token requires non-empty device and token text")
        if device_id in device_tokens:
            parser.error("--device-token device IDs must be unique")
        device_tokens[device_id] = token
    if args.serve and not device_tokens:
        parser.error("--serve requires at least one --device-token")
    if not args.serve and device_tokens:
        parser.error("--device-token requires --serve")
    args.device_tokens = device_tokens
    return args


def _runtime(args) -> ControlPlaneRuntime:
    if args.mock:
        return ControlPlaneRuntime.with_mock()
    hardware_tx_enabled = (
        args.enable_hardware_tx and args.acknowledge_transmit_risk
    )
    launcher = None
    if args.launch_rigctld:
        config = RigctldConfig(
            model_id=args.model_id,
            device=args.device,
            baud=args.baud,
            port=args.rigctld_port,
            hardware_tx_enabled=hardware_tx_enabled,
        )
        launcher = RigctldLauncher(config)
    return ControlPlaneRuntime(
        host=args.rigctld_host,
        port=args.rigctld_port,
        launcher=launcher,
        hardware_tx_enabled=hardware_tx_enabled,
    )


async def _run(args) -> int:
    if args.public_dummy_test:
        web_root = Path(__file__).resolve().parents[2] / "web"
        stack = PublicDummyStack(
            PublicDummyConfig(
                web_root=web_root,
                http_port=args.http_port,
                websocket_port=args.port,
                rigctld_port=args.rigctld_port,
            )
        )
        try:
            startup = await stack.start()
            _write_event(public_dummy_startup_event(startup))
            await asyncio.Event().wait()
        finally:
            await stack.close()
        return 0
    runtime = _runtime(args)
    async with runtime:
        if args.serve:
            server = RemoteRadioServer(runtime.gateway, args.device_tokens)
            try:
                await server.serve(host=args.host, port=args.port)
                await asyncio.Event().wait()
            finally:
                await server.close()
        _write_event(await runtime.gateway.initial_event())
        _write_event(serialize_snapshot(runtime.state_store.snapshot()))
        if args.once:
            return 0
        principal = Principal("cli-device")
        while True:
            raw_line = await asyncio.to_thread(sys.stdin.buffer.readline)
            if raw_line == b"":
                return 0
            try:
                line = raw_line.decode("utf-8", "strict")
            except UnicodeDecodeError:
                _write_event(
                    GatewayError("invalid_utf8", "input is not valid UTF-8").to_event()
                )
                continue
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                _write_event(
                    GatewayError("invalid_json", "input is not valid JSON").to_event()
                )
                continue
            try:
                event = await runtime.gateway.handle(principal, message)
            except GatewayError as error:
                event = error.to_event()
            _write_event(event)


def _write_event(event) -> None:
    sys.stdout.write(serialize_json_event(event) + "\n")
    sys.stdout.flush()


def public_dummy_startup_event(startup: PublicDummyStartup) -> dict[str, object]:
    if not isinstance(startup, PublicDummyStartup):
        raise TypeError("startup must be PublicDummyStartup")
    return {
        "type": "public-dummy.started",
        "url": startup.url,
        "websocket_url": startup.websocket_url,
        "device_id": startup.device_id,
        "token": startup.token,
        "identity": dict(startup.identity),
    }


def main(argv=None) -> int:
    args = _validated_args(argv)
    return asyncio.run(_run(args))


if __name__ == "__main__":
    raise SystemExit(main())
