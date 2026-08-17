import unittest

from remote_radio_server.rig.models import Lifecycle, RigResponse, RigState
from remote_radio_server.rig.errors import RigReportError


class RigStateTests(unittest.TestCase):
    def test_state_is_immutable_and_starts_offline(self):
        state = RigState()

        self.assertEqual(state.lifecycle, Lifecycle.OFFLINE)
        with self.assertRaises(AttributeError):
            state.lifecycle = Lifecycle.READY

    def test_report_error_marks_only_unimplemented_and_unavailable_unsupported(self):
        self.assertTrue(RigReportError(-4).is_unsupported)
        self.assertTrue(RigReportError(-11).is_unsupported)
        self.assertFalse(RigReportError(-12).is_unsupported)

    def test_response_preserves_unlabelled_values_without_changing_positional_fields(self):
        response = RigResponse("hamlib_version", (), 0, ("Hamlib 4.7.1",))

        self.assertEqual(("Hamlib 4.7.1",), response.values)


if __name__ == "__main__":
    unittest.main()
