"""Hamlib rigctld Extended Response Protocol framing."""

import codecs
import re

from .errors import RigProtocolError
from .models import RigResponse


def encode_command(command: str) -> bytes:
    if "\n" in command or "\r" in command:
        raise ValueError("rigctld commands must be one line")
    return f"|{command}\n".encode("ascii")


class ExtendedResponseParser:
    """Incrementally frame ``|``-delimited rigctld responses."""

    def __init__(self, max_buffer_bytes: int = 262_144):
        self._buffer = ""
        self._max_buffer_bytes = max_buffer_bytes
        self._decoder = codecs.getincrementaldecoder("utf-8")("strict")

    def feed(self, data: bytes) -> tuple[RigResponse, ...]:
        try:
            self._buffer += self._decoder.decode(data, final=False)
        except UnicodeDecodeError as error:
            self._reset_current_response(clear_buffer=True)
            raise RigProtocolError("response contains invalid UTF-8") from error
        self._enforce_limit()

        completed: list[RigResponse] = []
        while True:
            terminal = self._terminal()
            self._reject_complete_malformed_report(
                None if terminal is None else terminal[0]
            )
            if terminal is None:
                break
            payload_end, consumed_end, report = terminal
            payload = self._buffer[:payload_end]
            self._buffer = self._buffer[consumed_end:]
            completed.append(self._parse_response(payload, report))
            self._enforce_limit()
        return tuple(completed)

    @property
    def has_trailing_data(self) -> bool:
        """Whether a completed response was followed by non-framing bytes."""
        undecoded_bytes, _ = self._decoder.getstate()
        return bool(undecoded_bytes) or self._buffer not in {"", "\n", "\r\n"}

    def _enforce_limit(self) -> None:
        undecoded_bytes, _ = self._decoder.getstate()
        buffered_bytes = len(self._buffer.encode("utf-8")) + len(undecoded_bytes)
        if buffered_bytes > self._max_buffer_bytes:
            self._reset_current_response(clear_buffer=True)
            raise RigProtocolError("response exceeds configured limit")

    def _reset_current_response(self, *, clear_buffer: bool = False) -> None:
        if clear_buffer:
            self._buffer = ""
            self._decoder.reset()

    def _terminal(self) -> tuple[int, int, int] | None:
        pipe = re.search(r"\|RPRT (-?\d+)\|(?:\r?\n)?", self._buffer)
        newline = re.search(r"(?:^|[|\n])RPRT (-?\d+)\r?\n", self._buffer)
        matches = [match for match in (pipe, newline) if match is not None]
        if not matches:
            return None
        match = min(matches, key=lambda candidate: candidate.start())
        return match.start(), match.end(), int(match.group(1))

    def _reject_complete_malformed_report(
        self, valid_terminal_start: int | None
    ) -> None:
        malformed = re.search(r"\|RPRT[^|\r\n]*(?:\||\r?\n)", self._buffer)
        if malformed is not None and (
            valid_terminal_start is None or malformed.start() < valid_terminal_start
        ):
            self._reset_current_response(clear_buffer=True)
            raise RigProtocolError("response has a malformed report code")

    def _parse_response(self, payload: str, report: int) -> RigResponse:
        records = payload.split("|")
        if not records:
            raise RigProtocolError("response is missing a command header")

        header, *records = records
        header_match = re.fullmatch(r"([a-z][a-z0-9_]*):(?: .*)?", header)
        if header_match is None:
            raise RigProtocolError("response has a malformed command header")

        fields: list[tuple[str, str]] = []
        values: list[str] = []
        for record in records:
            key, separator, value = record.partition(":")
            if separator and key and key == key.strip() and "\n" not in key and value[:1] in {" ", "\t"}:
                fields.append((key, value.lstrip(" \t")))
            elif re.fullmatch(r"[A-Za-z][A-Za-z0-9_ ]*=.*", record):
                raise RigProtocolError("response has a malformed field")
            elif record:
                values.append(record)

        return RigResponse(
            command=header_match.group(1),
            fields=tuple(fields),
            report=report,
            values=tuple(values),
        )
