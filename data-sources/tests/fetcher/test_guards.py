import pytest

from fetcher.browser import DocumentResponse
from fetcher.guards import BLOCKED_RESOURCE_TYPES, RequestFilter, first_non_public_hop
from fetcher.urlcheck import HostChecker
from tests.fetcher.fakes import resolver

pytestmark = pytest.mark.anyio

DNS = {
    "intranet.example": ["10.0.0.7"],
    "gone.example": OSError("Name or service not known"),
    "bad.example": UnicodeError("label too long"),
}


def a_filter():
    return RequestFilter(HostChecker(resolver(DNS)))


@pytest.mark.parametrize("resource_type", sorted(BLOCKED_RESOURCE_TYPES))
async def test_assets_are_blocked_even_from_a_public_host(resource_type):
    assert await a_filter()("https://books.example/x", resource_type, False) is False


@pytest.mark.parametrize("resource_type", ["document", "script", "xhr", "fetch"])
async def test_requests_to_a_public_host_go_out(resource_type):
    is_navigation = resource_type == "document"
    assert await a_filter()("https://books.example/x", resource_type, is_navigation) is True


async def test_a_private_host_is_refused_and_only_a_refused_navigation_is_remembered():
    request_filter = a_filter()
    assert await request_filter("http://intranet.example/api", "xhr", False) is False
    assert request_filter.blocked_navigations == []
    assert await request_filter("http://intranet.example/", "document", True) is False
    assert request_filter.blocked_navigations == ["intranet.example"]


async def test_hosts_that_do_not_resolve_or_cannot_be_hostnames_are_refused():
    request_filter = a_filter()
    assert await request_filter("https://gone.example/", "script", False) is False
    assert await request_filter("https://bad.example/", "script", False) is False


@pytest.mark.parametrize(
    "url", ["data:text/html,hi", "blob:https://books.example/1", "about:blank"]
)
async def test_urls_that_never_touch_the_network_are_allowed(url):
    assert await a_filter()(url, "document", True) is True


async def test_each_host_is_resolved_once_per_filter():
    dns = resolver(DNS)
    request_filter = RequestFilter(HostChecker(dns))
    for path in ("a.js", "b.js", "c.js"):
        await request_filter(f"https://books.example/{path}", "script", False)
    assert dns.calls == ["books.example"]


async def test_a_clean_redirect_chain_has_no_non_public_hop():
    responses = [
        DocumentResponse(
            "https://books.example/b", 200, redirect_chain=("https://books.example/a",)
        )
    ]
    assert await first_non_public_hop(responses, HostChecker(resolver(DNS))) is None


async def test_a_private_hop_inside_a_redirect_chain_is_found():
    chain = ("https://books.example/a", "http://intranet.example/x")
    responses = [DocumentResponse("https://books.example/b", 200, redirect_chain=chain)]
    assert await first_non_public_hop(responses, HostChecker(resolver(DNS))) == (
        "intranet.example",
        "resolves to non-public address 10.0.0.7",
    )


async def test_a_private_final_url_is_found():
    responses = [
        DocumentResponse("https://books.example/", 403),
        DocumentResponse("http://intranet.example/", 200),
    ]
    hop = await first_non_public_hop(responses, HostChecker(resolver(DNS)))
    assert hop == ("intranet.example", "resolves to non-public address 10.0.0.7")


async def test_a_hop_that_no_longer_resolves_fails_closed():
    responses = [DocumentResponse("https://gone.example/", 200)]
    hop = await first_non_public_hop(responses, HostChecker(resolver(DNS)))
    assert hop == ("gone.example", "no longer resolves")


async def test_hops_without_a_host_are_skipped():
    responses = [DocumentResponse("about:blank", 200)]
    assert await first_non_public_hop(responses, HostChecker(resolver(DNS))) is None
