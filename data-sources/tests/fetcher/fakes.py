"""Test stand-ins for the fetcher's two external dependencies: DNS and the browser."""

from __future__ import annotations

PUBLIC_ADDRESS = "93.184.215.14"


def resolver(table: dict[str, list[str] | BaseException]):
    """A fake DNS. `table` maps a host to its addresses or to an exception to
    raise; any other host resolves to one public address. `.calls` records
    every host asked for, in order."""
    calls: list[str] = []

    async def resolve(host: str) -> list[str]:
        calls.append(host)
        answer = table.get(host, [PUBLIC_ADDRESS])
        if isinstance(answer, BaseException):
            raise answer
        return answer

    resolve.calls = calls  # type: ignore[attr-defined]
    return resolve
