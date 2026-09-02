class AuthError(Exception):
    def __init__(
        self,
        code: str,
        http_status: int,
        safe_message: str,
        retry_after_s: int | None = None,
    ) -> None:
        self.code = code
        self.http_status = http_status
        self.safe_message = safe_message
        self.retry_after_s = retry_after_s
        super().__init__(safe_message)


class AuthFailure(AuthError):
    def __init__(self, code: str) -> None:
        super().__init__(code, 401, "Authentication failed.")


class AuthForbidden(AuthError):
    def __init__(self, code: str = "forbidden") -> None:
        super().__init__(code, 403, "The requested action is not permitted.")


class AuthConflict(AuthError):
    def __init__(self, code: str) -> None:
        super().__init__(code, 409, "The request conflicts with the current state.")


class AuthGone(AuthError):
    def __init__(self, code: str) -> None:
        super().__init__(code, 410, "The requested resource is no longer available.")


class AuthRateLimited(AuthError):
    def __init__(self, code: str, retry_after_s: int) -> None:
        super().__init__(code, 429, "Too many requests.", retry_after_s)
