import asyncio
import unittest
from unittest.mock import patch

from remote_radio_server.rig.launcher import (
    RigctldConfig,
    RigctldLauncher,
    build_rigctld_args,
)


class RecordingProcess:
    def __init__(
        self,
        *,
        timeout_until_killed: bool = False,
        hang_after_kill: bool = False,
        post_kill_error: BaseException | None = None,
        returncode=None,
    ):
        self.returncode = returncode
        self.timeout_until_killed = timeout_until_killed
        self.hang_after_kill = hang_after_kill
        self.post_kill_error = post_kill_error
        self.terminate_calls = 0
        self.kill_calls = 0
        self.wait_calls = 0
        self.wait_started = asyncio.Event()

    def terminate(self):
        self.terminate_calls += 1
        if not self.timeout_until_killed:
            self.returncode = 0

    def kill(self):
        self.kill_calls += 1
        if not self.hang_after_kill and self.post_kill_error is None:
            self.returncode = -9

    async def wait(self):
        self.wait_calls += 1
        self.wait_started.set()
        if self.kill_calls and self.post_kill_error is not None:
            raise self.post_kill_error
        if self.kill_calls and self.hang_after_kill:
            await asyncio.Event().wait()
        if self.timeout_until_killed and self.returncode is None:
            await asyncio.Event().wait()
        return self.returncode


class RecordingProcessFactory:
    def __init__(self, process, *, gate: asyncio.Event | None = None):
        self.process = process
        self.gate = gate
        self.calls = []
        self.started = asyncio.Event()

    async def __call__(self, *args, **kwargs):
        self.calls.append((args, kwargs))
        self.started.set()
        if self.gate is not None:
            await self.gate.wait()
        await asyncio.sleep(0)
        return self.process


class RigctldArgumentTests(unittest.TestCase):
    def test_binds_loopback_and_preserves_explicit_device_as_one_element(self):
        args = build_rigctld_args(
            RigctldConfig(
                model_id=1049,
                device="/dev/serial/by-id/Yaesu FT-710; untouched",
                baud=38400,
            )
        )

        self.assertEqual(
            [
                "rigctld", "-m", "1049",
                "-r", "/dev/serial/by-id/Yaesu FT-710; untouched",
                "-s", "38400", "-T", "127.0.0.1", "-t", "4532",
            ],
            args,
        )

    def test_omits_baud_when_unspecified_and_hardware_tx_adds_no_flag(self):
        args = build_rigctld_args(
            RigctldConfig(model_id=1049, device="COM7", hardware_tx_enabled=True)
        )

        self.assertEqual(
            ["rigctld", "-m", "1049", "-r", "COM7", "-T", "127.0.0.1", "-t", "4532"],
            args,
        )

    def test_rejects_non_exact_loopback_hosts(self):
        for host in ("0.0.0.0", "::", "localhost", "127.0.0.01", "127.0.0.2"):
            with self.subTest(host=host), self.assertRaises(ValueError):
                build_rigctld_args(RigctldConfig(1049, "COM7", host=host))

    def test_rejects_invalid_integer_boolean_and_device_inputs(self):
        invalid_configs = (
            RigctldConfig(True, "COM7"),
            RigctldConfig(0, "COM7"),
            RigctldConfig(1049, ""),
            RigctldConfig(1049, "   "),
            RigctldConfig(1049, "COM7\r-injected"),
            RigctldConfig(1049, "COM7\n-injected"),
            RigctldConfig(1049, "COM7\0-injected"),
            RigctldConfig(1049, "COM7", baud=True),
            RigctldConfig(1049, "COM7", baud=0),
            RigctldConfig(1049, "COM7", port=True),
            RigctldConfig(1049, "COM7", port=0),
            RigctldConfig(1049, "COM7", port=65536),
            RigctldConfig(1049, "COM7", hardware_tx_enabled=1),
        )
        for config in invalid_configs:
            with self.subTest(config=config), self.assertRaises((TypeError, ValueError)):
                build_rigctld_args(config)

    def test_rejects_non_finite_terminate_timeout(self):
        for timeout in (float("nan"), float("inf"), float("-inf")):
            with self.subTest(timeout=timeout), self.assertRaises(ValueError):
                RigctldLauncher(
                    RigctldConfig(1049, "COM7"), terminate_timeout_s=timeout
                )


class RigctldProcessTests(unittest.IsolatedAsyncioTestCase):
    async def test_close_cancellation_finishes_bounded_cleanup_before_propagating(self):
        process = RecordingProcess(timeout_until_killed=True)
        launcher = RigctldLauncher(
            RigctldConfig(1049, "COM7"),
            process_factory=RecordingProcessFactory(process),
            terminate_timeout_s=0.005,
        )
        await launcher.start()
        close_task = asyncio.create_task(launcher.close())
        await process.wait_started.wait()

        close_task.cancel()

        with self.assertRaises(asyncio.CancelledError):
            await asyncio.wait_for(close_task, 0.1)
        self.assertEqual(1, process.terminate_calls)
        self.assertEqual(1, process.kill_calls)
        self.assertEqual(2, process.wait_calls)
        self.assertIsNone(launcher.process)

    async def test_post_kill_wait_is_bounded_and_retains_live_process_for_retry(self):
        process = RecordingProcess(timeout_until_killed=True, hang_after_kill=True)
        launcher = RigctldLauncher(
            RigctldConfig(1049, "COM7"),
            process_factory=RecordingProcessFactory(process),
            terminate_timeout_s=0.005,
        )
        await launcher.start()

        with self.assertRaises(asyncio.TimeoutError):
            await asyncio.wait_for(launcher.close(), 0.1)

        self.assertEqual(1, process.terminate_calls)
        self.assertEqual(1, process.kill_calls)
        self.assertEqual(2, process.wait_calls)
        self.assertIs(process, launcher.process)
        process.returncode = -9
        await launcher.close()
        self.assertIsNone(launcher.process)

    async def test_post_kill_wait_error_retains_live_process_for_retry(self):
        process = RecordingProcess(
            timeout_until_killed=True,
            post_kill_error=OSError("wait failed"),
        )
        launcher = RigctldLauncher(
            RigctldConfig(1049, "COM7"),
            process_factory=RecordingProcessFactory(process),
            terminate_timeout_s=0.005,
        )
        await launcher.start()

        with self.assertRaisesRegex(OSError, "wait failed"):
            await launcher.close()

        self.assertIs(process, launcher.process)
        process.returncode = -9
        await launcher.close()
        self.assertIsNone(launcher.process)

    async def test_close_started_during_process_creation_cleans_created_process(self):
        creation_gate = asyncio.Event()
        process = RecordingProcess()
        factory = RecordingProcessFactory(process, gate=creation_gate)
        launcher = RigctldLauncher(
            RigctldConfig(1049, "COM7"), process_factory=factory
        )
        start_task = asyncio.create_task(launcher.start())
        await factory.started.wait()
        close_task = asyncio.create_task(launcher.close())
        await asyncio.sleep(0)
        self.assertFalse(close_task.done())

        creation_gate.set()
        await asyncio.gather(start_task, close_task)

        self.assertEqual(1, len(factory.calls))
        self.assertEqual(1, process.terminate_calls)
        self.assertIsNone(launcher.process)

    async def test_default_process_creation_uses_exec_and_never_shell(self):
        process = RecordingProcess()
        factory = RecordingProcessFactory(process)
        with (
            patch(
                "remote_radio_server.rig.launcher.asyncio.create_subprocess_exec",
                new=factory,
            ),
            patch(
                "remote_radio_server.rig.launcher.asyncio.create_subprocess_shell",
                side_effect=AssertionError("shell process creation is prohibited"),
            ),
        ):
            launcher = RigctldLauncher(RigctldConfig(1049, "COM 7"))
            await launcher.start()

        self.assertIs(process, launcher.process)
        self.assertEqual({}, factory.calls[0][1])
        self.assertEqual("rigctld", factory.calls[0][0][0])
        await launcher.close()

    async def test_start_is_idempotent_and_uses_exec_argument_vector_without_shell(self):
        process = RecordingProcess()
        factory = RecordingProcessFactory(process)
        launcher = RigctldLauncher(
            RigctldConfig(1049, "COM 7", baud=38400),
            process_factory=factory,
        )

        await asyncio.gather(launcher.start(), launcher.start())

        self.assertEqual(1, len(factory.calls))
        args, kwargs = factory.calls[0]
        self.assertEqual(
            (
                "rigctld", "-m", "1049", "-r", "COM 7", "-s", "38400",
                "-T", "127.0.0.1", "-t", "4532",
            ),
            args,
        )
        self.assertEqual({}, kwargs)
        self.assertIs(process, launcher.process)
        self.assertFalse(launcher.hardware_tx_enabled)
        await launcher.close()

    async def test_close_is_idempotent_and_terminates_then_waits_without_killing(self):
        process = RecordingProcess()
        launcher = RigctldLauncher(
            RigctldConfig(1049, "COM7"),
            process_factory=RecordingProcessFactory(process),
        )
        await launcher.start()

        await asyncio.gather(launcher.close(), launcher.close())

        self.assertEqual(1, process.terminate_calls)
        self.assertEqual(1, process.wait_calls)
        self.assertEqual(0, process.kill_calls)
        self.assertIsNone(launcher.process)

    async def test_close_kills_only_after_terminate_wait_times_out(self):
        process = RecordingProcess(timeout_until_killed=True)
        launcher = RigctldLauncher(
            RigctldConfig(1049, "COM7", hardware_tx_enabled=True),
            process_factory=RecordingProcessFactory(process),
            terminate_timeout_s=0.001,
        )
        await launcher.start()

        await launcher.close()

        self.assertEqual(1, process.terminate_calls)
        self.assertEqual(2, process.wait_calls)
        self.assertEqual(1, process.kill_calls)
        self.assertTrue(launcher.hardware_tx_enabled)

    async def test_close_does_not_signal_a_process_that_already_exited(self):
        process = RecordingProcess(returncode=0)
        launcher = RigctldLauncher(
            RigctldConfig(1049, "COM7"),
            process_factory=RecordingProcessFactory(process),
        )
        await launcher.start()

        await launcher.close()

        self.assertEqual(0, process.terminate_calls)
        self.assertEqual(0, process.kill_calls)


if __name__ == "__main__":
    unittest.main()
