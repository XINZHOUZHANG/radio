import hashlib
from dataclasses import dataclass

from .passwords import normalize_username
from .repository import AuthRepository


@dataclass(frozen=True, slots=True)
class ThrottleDecision:
    retry_after_s: int


class LoginThrottle:
    def __init__(self, repository: AuthRepository) -> None:
        self._repository = repository

    async def check(self, username: str, source: str) -> ThrottleDecision:
        account_scope, source_scope = _scope_keys(username, source)
        retry_after_s = await self._repository.login_throttle_retry_after(
            (account_scope, source_scope)
        )
        return ThrottleDecision(retry_after_s)

    async def failure(self, username: str, source: str) -> ThrottleDecision:
        account_scope, source_scope = _scope_keys(username, source)
        retry_after_s = await self._repository.record_login_failure(
            account_scope, source_scope
        )
        return ThrottleDecision(retry_after_s)

    async def success(self, username: str, source: str) -> None:
        account_scope, _ = _scope_keys(username, source)
        await self._repository.clear_login_throttle(account_scope)


def _scope_keys(username: str, source: str) -> tuple[str, str]:
    normalized_username = normalize_username(username)
    account_name = f"account:{normalized_username}:{source}"
    source_name = f"source:{source}"
    return _digest(account_name), _digest(source_name)


def _digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()
