import asyncio
import os
from pathlib import Path
import shutil
import socket
import subprocess
import unittest

from remote_radio_server.gateway import serialize_snapshot
from remote_radio_server.runtime import ControlPlaneRuntime


def _rigctld_executable():
    configured = os.environ.get("REMOTE_RADIO_RIGCTLD")
    if configured and Path(configured).is_file():
        return configured
    return shutil.which("rigctld")


def _ephemeral_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


@unittest.skipUnless(
    _rigctld_executable(),
    "official rigctld is not explicitly available on PATH or REMOTE_RADIO_RIGCTLD",
)
class HamlibDummyTests(unittest.IsolatedAsyncioTestCase):
    async def test_dummy_model_reaches_ready_snapshot_without_ptt(self):
        executable = _rigctld_executable()
        port = _ephemeral_port()
        process = await asyncio.to_thread(
            subprocess.Popen,
            (
                executable,
                "-m",
                "1",
                "-T",
                "127.0.0.1",
                "-t",
                str(port),
            ),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        runtime = ControlPlaneRuntime(port=port, ready_timeout_s=8.0)
        try:
            await runtime.start()
            snapshot = serialize_snapshot(runtime.state_store.snapshot())
            self.assertEqual("ready", snapshot["lifecycle"])
            self.assertEqual("rig.snapshot", snapshot["type"])
        finally:
            await runtime.close()
            if process.returncode is None:
                process.terminate()
                try:
                    await asyncio.wait_for(
                        asyncio.to_thread(process.wait), 2.0
                    )
                except asyncio.TimeoutError:
                    process.kill()
                    await asyncio.to_thread(process.wait)


if __name__ == "__main__":
    unittest.main()
