import re
import unicodedata
from dataclasses import dataclass

from argon2 import PasswordHasher, Type
from argon2.exceptions import InvalidHashError, VerificationError


_USERNAME_PATTERN = re.compile(r"[a-z0-9][a-z0-9_.-]{2,31}", re.ASCII)
_BLOCKED_PASSWORDS = frozenset(
    {
        "passwordpassword",
        "qwertyqwertyqwerty",
        "letmeinletmein",
        "administratoradmin",
        "remoteradioremote",
        "remote-radio-admin",
        "123456789012345",
        "000000000000000",
    }
)
_PRODUCT_NAME = "remoteradio"
_DUMMY_PASSWORD = "remote-radio-dummy-password"


@dataclass(frozen=True, slots=True)
class PasswordCheck:
    valid: bool
    needs_rehash: bool


def normalize_username(value: str) -> str:
    normalized = value.strip().lower()
    if _USERNAME_PATTERN.fullmatch(normalized) is None:
        raise ValueError("username must be a valid ASCII identifier")
    return normalized


class PasswordService:
    def __init__(self) -> None:
        self._hasher = PasswordHasher(
            time_cost=2,
            memory_cost=19_456,
            parallelism=1,
            hash_len=32,
            salt_len=16,
            type=Type.ID,
        )
        self._dummy_phc = self._hasher.hash(_DUMMY_PASSWORD)

    def validate(self, username: str, password: str) -> str:
        normalized = unicodedata.normalize("NFC", password)
        if not 15 <= len(normalized) <= 128:
            raise ValueError("password must contain between 15 and 128 code points")
        try:
            encoded = normalized.encode("utf-8")
        except UnicodeEncodeError as error:
            raise ValueError("password must contain valid Unicode") from error
        if len(encoded) > 1_024:
            raise ValueError("password must contain no more than 1024 UTF-8 bytes")

        comparison = normalized.casefold()
        normalized_username = normalize_username(username)
        if comparison in _BLOCKED_PASSWORDS:
            raise ValueError("password is too common")
        if normalized_username * 2 in comparison or _PRODUCT_NAME * 2 in comparison:
            raise ValueError("password is too closely related to its context")
        return normalized

    def hash(self, password: str) -> str:
        return self._hasher.hash(password)

    def verify(self, password: str, phc: str) -> PasswordCheck:
        try:
            valid = self._hasher.verify(phc, password)
        except (VerificationError, InvalidHashError):
            return PasswordCheck(False, False)
        return PasswordCheck(valid, valid and self._hasher.check_needs_rehash(phc))

    def verify_unavailable(self, password: str) -> PasswordCheck:
        try:
            self._hasher.verify(self._dummy_phc, password)
        except (VerificationError, InvalidHashError):
            pass
        return PasswordCheck(False, False)
