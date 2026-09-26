"""Which URLs the service will fetch (spec §6): http or https, no embedded
credentials, and a host that resolves only to public addresses.

`HostChecker` caches each host's answer for its own lifetime. The fetcher makes
one per fetch, so the cache covers exactly one page load's requests and a DNS
change between fetches is always seen.
"""

from __future__ import annotations

import asyncio
import ipaddress
import socket
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from urllib.parse import urlsplit

Resolver = Callable[[str], Awaitable[list[str]]]


class InvalidUrl(ValueError):
    """Not a URL the service will fetch. Maps to 400 invalid_url."""


class Unresolvable(RuntimeError):
    """The host's lookup failed or returned nothing. Maps to 502 upstream_unreachable."""


@dataclass(frozen=True)
class Target:
    url: str
    host: str


async def system_resolver(host: str) -> list[str]:
    loop = asyncio.get_running_loop()
    infos = await loop.getaddrinfo(host, None, type=socket.SOCK_STREAM)
    return [info[4][0] for info in infos]


def parse(url: str) -> Target:
    try:
        parts = urlsplit(url)
        _ = parts.port  # raises ValueError on a malformed or out-of-range port
    except ValueError as exc:
        raise InvalidUrl(f"not a valid URL: {exc}") from None
    if parts.scheme not in ("http", "https"):
        raise InvalidUrl(f"the scheme must be http or https, not {parts.scheme or 'missing'}")
    if parts.username is not None or parts.password is not None:
        raise InvalidUrl("the URL must not embed credentials")
    if not parts.hostname:
        raise InvalidUrl("the URL has no host")
    return Target(url=url, host=parts.hostname)


def is_public(address: str) -> bool:
    ip = ipaddress.ip_address(address.split("%", 1)[0])
    if isinstance(ip, ipaddress.IPv6Address):
        # An IPv6 form can carry an IPv4 address inside it; judge that too.
        for embedded in (ip.ipv4_mapped, ip.sixtofour):
            if embedded is not None and not is_public(str(embedded)):
                return False
    return ip.is_global and not (
        ip.is_multicast or ip.is_reserved or ip.is_loopback or ip.is_link_local or ip.is_unspecified
    )


class HostChecker:
    def __init__(self, resolver: Resolver = system_resolver) -> None:
        self._resolver = resolver
        self._answers: dict[str, str | None] = {}

    async def non_public_address(self, host: str) -> str | None:
        """The first address `host` resolves to that is not public, or None when
        all are. Raises Unresolvable when the lookup fails, InvalidUrl when the
        host cannot be a hostname at all."""
        if host in self._answers:
            return self._answers[host]
        try:
            addresses = await self._resolver(host)
        except UnicodeError:
            # getaddrinfo IDNA-encodes the host first; a label over 63
            # characters fails here, before any lookup.
            raise InvalidUrl(f"{host!r} is not a valid hostname") from None
        except OSError as exc:  # socket.gaierror is an OSError
            raise Unresolvable(f"{host} did not resolve: {exc}") from None
        if not addresses:
            raise Unresolvable(f"{host} resolved to no addresses")
        answer = next((address for address in addresses if not is_public(address)), None)
        self._answers[host] = answer
        return answer

    async def check(self, url: str) -> Target:
        target = parse(url)
        bad = await self.non_public_address(target.host)
        if bad is not None:
            raise InvalidUrl(f"{target.host} resolves to non-public address {bad}")
        return target
