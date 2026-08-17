import unittest

from remote_radio_server.rig.extensions import extension_for
from remote_radio_server.rig.extensions.ft710 import Ft710Extension
from remote_radio_server.rig.models import RigIdentity


def rig_identity(manufacturer="Yaesu", model="FT-710", model_id=None):
    return RigIdentity(manufacturer, model, model_id, None, None)


class RecordingCallable:
    def __init__(self, result):
        self.result = result
        self.calls = []

    async def __call__(self, *args, **kwargs):
        self.calls.append((args, kwargs))
        return self.result


class ExtensionIdentityTests(unittest.TestCase):
    def test_ft710_extension_requires_normalized_exact_identity(self):
        self.assertIsInstance(
            extension_for(rig_identity("  yAeSu ", " ft-710 ", 1049)),
            Ft710Extension,
        )
        self.assertIsInstance(extension_for(rig_identity(model_id=None)), Ft710Extension)

        rejected = (
            rig_identity(model="FTDX10"),
            rig_identity(model="FT-710 Field"),
            rig_identity(manufacturer="Not Yaesu"),
            rig_identity(model_id=1035),
        )
        for identity in rejected:
            with self.subTest(identity=identity):
                self.assertIsNone(extension_for(identity))

    def test_lookup_is_pure_and_does_not_invoke_injected_seams(self):
        raw_query = RecordingCallable("raw")
        safe_tune = RecordingCallable("tuned")

        extension = extension_for(
            rig_identity(), raw_query=raw_query, safe_tune=safe_tune
        )

        self.assertIsInstance(extension, Ft710Extension)
        self.assertEqual([], raw_query.calls)
        self.assertEqual([], safe_tune.calls)


class Ft710DelegationTests(unittest.IsolatedAsyncioTestCase):
    async def test_raw_query_delegates_only_to_administrator_guarded_seam(self):
        raw_query = RecordingCallable({"status": "confirmed"})
        safe_tune = RecordingCallable("unused")
        extension = extension_for(
            rig_identity(), raw_query=raw_query, safe_tune=safe_tune
        )

        result = await extension.raw_query("; AC;")

        self.assertEqual({"status": "confirmed"}, result)
        self.assertEqual([(("; AC;",), {})], raw_query.calls)
        self.assertEqual([], safe_tune.calls)

    async def test_tune_delegates_only_to_safety_mediated_seam(self):
        raw_query = RecordingCallable("unused")
        safe_tune = RecordingCallable({"status": "confirmed"})
        extension = extension_for(
            rig_identity(), raw_query=raw_query, safe_tune=safe_tune
        )

        result = await extension.tune(True)

        self.assertEqual({"status": "confirmed"}, result)
        self.assertEqual([((True,), {})], safe_tune.calls)
        self.assertEqual([], raw_query.calls)

    async def test_missing_injected_seams_fail_explicitly_without_io(self):
        extension = extension_for(rig_identity())

        with self.assertRaisesRegex(RuntimeError, "raw-query seam"):
            await extension.raw_query("; AC;")
        with self.assertRaisesRegex(RuntimeError, "safe-tune seam"):
            await extension.tune(True)


if __name__ == "__main__":
    unittest.main()
