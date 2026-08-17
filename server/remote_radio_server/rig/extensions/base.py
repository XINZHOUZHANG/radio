"""Model-extension boundary constrained to pre-guarded callables."""


class RigExtension:
    def __init__(self, *, raw_query=None, safe_tune=None) -> None:
        self._raw_query_seam = raw_query
        self._safe_tune_seam = safe_tune

    async def raw_query(self, request: str):
        if self._raw_query_seam is None:
            raise RuntimeError("administrator raw-query seam is not configured")
        return await self._raw_query_seam(request)

    async def tune(self, enabled: bool):
        if self._safe_tune_seam is None:
            raise RuntimeError("safe-tune seam is not configured")
        return await self._safe_tune_seam(enabled)
