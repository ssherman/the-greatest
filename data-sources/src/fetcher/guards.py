"""The address checks that run during and after a fetch (spec §6).

`RequestFilter` goes to the browser and decides, for every request the page
makes, whether it goes out. `first_non_public_hop` is the backstop for what the
filter cannot see: Playwright calls a route handler only for the first URL of a
redirect chain, and Firefox repeats the DNS lookup after the filter's check, so
every main-frame hop is checked again after navigation.
"""

from __future__ import annotations

from urllib.parse import urlsplit

from fetcher.browser import DocumentResponse
from fetcher.urlcheck import HostChecker, InvalidUrl, Unresolvable

# Only the HTML matters; blocking these roughly halves page time (spec §2).
BLOCKED_RESOURCE_TYPES = frozenset({"image", "font", "media", "stylesheet"})


class RequestFilter:
    def __init__(self, hosts: HostChecker) -> None:
        self._hosts = hosts
        # Hosts of navigations refused for being non-public, so a navigation
        # failure they caused reads as invalid_url rather than browser_error.
        self.blocked_navigations: list[str] = []

    async def __call__(self, url: str, resource_type: str, is_navigation: bool) -> bool:
        if resource_type in BLOCKED_RESOURCE_TYPES:
            return False
        parts = urlsplit(url)
        if parts.scheme not in ("http", "https"):
            return True  # data:, blob:, about: -- nothing goes over the network
        if not parts.hostname:
            return False
        try:
            bad = await self._hosts.non_public_address(parts.hostname)
        except (InvalidUrl, Unresolvable):
            return False
        if bad is None:
            return True
        if is_navigation:
            self.blocked_navigations.append(parts.hostname)
        return False


async def first_non_public_hop(
    responses: list[DocumentResponse], hosts: HostChecker
) -> tuple[str, str] | None:
    """`(host, reason)` for the first hop, across every main-frame response and
    its redirect chain, whose host is not public; None when all are. A hop
    whose host no longer resolves counts: this check fails closed."""
    for response in responses:
        for hop in (*response.redirect_chain, response.url):
            host = urlsplit(hop).hostname
            if not host:
                continue
            try:
                bad = await hosts.non_public_address(host)
            except (InvalidUrl, Unresolvable):
                return host, "no longer resolves"
            if bad is not None:
                return host, f"resolves to non-public address {bad}"
    return None
