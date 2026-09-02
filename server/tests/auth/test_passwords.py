import unittest

from argon2 import PasswordHasher, Type, extract_parameters

from remote_radio_server.auth.passwords import PasswordService, normalize_username


class UsernamePolicyTests(unittest.TestCase):
    def test_username_is_trimmed_and_lowercased_without_changing_allowed_punctuation(self):
        self.assertEqual("operator.one-test_2", normalize_username("  Operator.One-Test_2\t"))

    def test_username_rejects_values_outside_the_ascii_identifier_policy(self):
        invalid_values = (
            "ab",
            "a" * 33,
            "_operator",
            "operator name",
            "opérator",
        )
        for value in invalid_values:
            with self.subTest(value=value), self.assertRaises(ValueError):
                normalize_username(value)


class PasswordPolicyTests(unittest.TestCase):
    def setUp(self):
        self.service = PasswordService()

    def test_validation_normalizes_nfc_before_enforcing_code_point_bounds(self):
        decomposed = "e\u0301" + "a" * 14
        expected = "é" + "a" * 14

        self.assertEqual(expected, self.service.validate("alice", decomposed))

    def test_validation_accepts_exact_code_point_bounds_and_spaces(self):
        accepted = (
            "a" * 15,
            "a" * 128,
            "correct horse battery staple",
        )
        for password in accepted:
            with self.subTest(length=len(password)):
                self.assertEqual(password, self.service.validate("alice", password))

    def test_validation_rejects_passwords_outside_code_point_bounds(self):
        for password in ("a" * 14, "a" * 129):
            with self.subTest(length=len(password)), self.assertRaises(ValueError):
                self.service.validate("alice", password)

    def test_validation_rejects_input_over_the_utf8_byte_cap(self):
        password = "é" * 600
        self.assertGreater(len(password.encode("utf-8")), 1_024)

        with self.assertRaises(ValueError):
            self.service.validate("alice", password)

    def test_validation_rejects_every_initial_blocklist_entry_case_insensitively(self):
        blocked = (
            "PASSWORDPASSWORD",
            "qwertyqwertyqwerty",
            "letmeinletmein",
            "administratoradmin",
            "remoteradioremote",
            "remote-radio-admin",
            "123456789012345",
            "000000000000000",
        )
        for password in blocked:
            with self.subTest(password=password), self.assertRaises(ValueError):
                self.service.validate("alice", password)

    def test_validation_rejects_repeated_username_equal_to_or_inside_password(self):
        blocked = (
            "operator.oneoperator.one",
            "prefix-OPERATOR.ONEoperator.one-suffix",
        )
        for password in blocked:
            with self.subTest(password=password), self.assertRaises(ValueError):
                self.service.validate("operator.one", password)

    def test_validation_rejects_two_product_names_inside_password(self):
        with self.assertRaises(ValueError):
            self.service.validate("alice", "prefix-RemoteRadioRemoteRadio-suffix")

    def test_hash_uses_approved_argon2id_parameters_and_random_salts(self):
        first = self.service.hash("correct horse battery staple")
        second = self.service.hash("correct horse battery staple")
        parameters = extract_parameters(first)

        self.assertEqual(Type.ID, parameters.type)
        self.assertGreaterEqual(parameters.memory_cost, 19_456)
        self.assertGreaterEqual(parameters.time_cost, 2)
        self.assertGreaterEqual(parameters.parallelism, 1)
        self.assertEqual(32, parameters.hash_len)
        self.assertEqual(16, parameters.salt_len)
        self.assertNotEqual(first, second)
        self.assertTrue(self.service.verify("correct horse battery staple", first).valid)

    def test_verify_returns_one_safe_result_for_wrong_or_malformed_hashes(self):
        encoded = self.service.hash("correct horse battery staple")

        self.assertEqual(
            self.service.verify("wrong horse battery staple", encoded),
            self.service.verify("wrong horse battery staple", "not-a-phc"),
        )
        self.assertFalse(self.service.verify("wrong horse battery staple", encoded).valid)
        self.assertFalse(
            self.service.verify("wrong horse battery staple", encoded).needs_rehash
        )

    def test_verify_reports_when_a_valid_hash_needs_rehash(self):
        old_hasher = PasswordHasher(
            time_cost=1,
            memory_cost=8_192,
            parallelism=1,
            hash_len=16,
            salt_len=8,
            type=Type.ID,
        )
        encoded = old_hasher.hash("correct horse battery staple")

        check = self.service.verify("correct horse battery staple", encoded)

        self.assertTrue(check.valid)
        self.assertTrue(check.needs_rehash)

    def test_unavailable_account_runs_dummy_verification_and_never_authenticates(self):
        check = self.service.verify_unavailable("correct horse battery staple")

        self.assertFalse(check.valid)
        self.assertFalse(check.needs_rehash)


if __name__ == "__main__":
    unittest.main()
