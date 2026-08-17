"""Pure lookup for narrowly matched rig model extensions."""

from ..models import RigIdentity
from .base import RigExtension
from .ft710 import Ft710Extension


def extension_for(
    identity: RigIdentity,
    *,
    raw_query=None,
    safe_tune=None,
) -> RigExtension | None:
    if not isinstance(identity, RigIdentity):
        return None
    manufacturer = identity.manufacturer.strip().casefold()
    model = identity.model.strip().casefold()
    if manufacturer != "yaesu" or model != "ft-710":
        return None
    if identity.model_id not in (None, 1049):
        return None
    return Ft710Extension(raw_query=raw_query, safe_tune=safe_tune)


__all__ = ["Ft710Extension", "RigExtension", "extension_for"]
