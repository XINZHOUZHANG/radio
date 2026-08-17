class RigError(Exception):
    """Base class for rig control errors."""


class RigProtocolError(RigError):
    pass


class RigTransportError(RigError):
    pass


class RigTransportClosed(RigTransportError):
    pass


class RigReportError(RigError):
    """A non-zero Hamlib report code returned by rigctld."""

    UNSUPPORTED_CODES = frozenset({-4, -11})

    def __init__(self, code: int, message: str = ""):
        self.code = code
        self.hamlib_code = code
        super().__init__(message or f"Hamlib report {code}")

    @property
    def is_unsupported(self) -> bool:
        return self.code in self.UNSUPPORTED_CODES


class RigCapabilityError(RigError):
    pass


class RigCommandError(RigError):
    pass


class GatewayError(Exception):
    pass
