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

# WHATWG "forbidden host code point" set, plus the ASCII range this service also
# refuses: C0 controls (U+0000-U+001F) and space (U+0020) truncate or confuse
# getaddrinfo; DEL (U+007F); backslash, which Firefox treats as `/` but Python's
# urlsplit does not, so a host like `127.0.0.1\.x.attacker.com` is one hostname
# to Python's resolver and a different one (`127.0.0.1`) to Firefox's navigation.
# `:` is forbidden only in a non-IP host -- checked separately, since a bracketed
# IPv6 literal's bracket-stripped form needs its colons.
_OTHER_FORBIDDEN_HOST_CHARS = frozenset("#/<>?@[]^|\\%:")


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
    host = parts.hostname
    try:
        ipaddress.ip_address(host)
    except ValueError:
        # Not an IP literal: colons are forbidden here too (a bracketed IPv6
        # literal's colons are exempted above, by parsing successfully).
        bad_char = _forbidden_host_char(host)
        if bad_char is not None:
            raise InvalidUrl(
                f"the host {host!r} contains a forbidden character: {bad_char!r}"
            ) from None
    return Target(url=url, host=host)


def _forbidden_host_char(host: str) -> str | None:
    """The first WHATWG forbidden host code point in `host`, or None."""
    for ch in host:
        if ord(ch) <= 0x20 or ord(ch) == 0x7F or ch in _OTHER_FORBIDDEN_HOST_CHARS:
            return ch
    return None


def is_public(address: str) -> bool:
    ip = ipaddress.ip_address(address.split("%", 1)[0])
    if isinstance(ip, ipaddress.IPv6Address):
        # An IPv6 form can carry an IPv4 address inside it; judge that too.
        for embedded in (ip.ipv4_mapped, ip.sixtofour):
            if embedded is not None and not is_public(str(embedded)):
                return False
    return ip.is_global and not (
        ip.is_multicast
        or ip.is_reserved
        or ip.is_loopback
        or ip.is_link_local
        or ip.is_unspecified
        or getattr(ip, "is_site_local", False)  # IPv6 fec0::/10; IPv4 has no such attribute
    )


class HostChecker:
    def __init__(self, resolver: Resolver = system_resolver) -> None:
        self._resolver = resolver
        self._answers: dict[str, str | None] = {}
        # A failed lookup is cached too, so a dead or unencodable host is not
        # re-resolved for every subresource on the page.
        self._errors: dict[str, InvalidUrl | Unresolvable] = {}

    async def non_public_address(self, host: str) -> str | None:
        """The first address `host` resolves to that is not public, or None when
        all are. Raises Unresolvable when the lookup fails, InvalidUrl when the
        host cannot be a hostname at all."""
        if host in self._answers:
            return self._answers[host]
        if host in self._errors:
            raise self._errors[host]
        try:
            addresses = await self._resolver(host)
        except UnicodeError:
            # getaddrinfo IDNA-encodes the host first; a label over 63
            # characters fails here, before any lookup.
            error: InvalidUrl | Unresolvable = InvalidUrl(f"{host!r} is not a valid hostname")
            self._errors[host] = error
            raise error from None
        except OSError as exc:  # socket.gaierror is an OSError
            error = Unresolvable(f"{host} did not resolve: {exc}")
            self._errors[host] = error
            raise error from None
        if not addresses:
            error = Unresolvable(f"{host} resolved to no addresses")
            self._errors[host] = error
            raise error
        answer = next((address for address in addresses if not is_public(address)), None)
        self._answers[host] = answer
        return answer

    async def check(self, url: str) -> Target:
        target = parse(url)
        bad = await self.non_public_address(target.host)
        if bad is not None:
            raise InvalidUrl(f"{target.host} resolves to non-public address {bad}")
        return target
