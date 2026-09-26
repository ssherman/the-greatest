import socket

import pytest

from fetcher.urlcheck import (
    HostChecker,
    InvalidUrl,
    Unresolvable,
    is_public,
    parse,
    system_resolver,
)
from tests.fetcher.fakes import PUBLIC_ADDRESS, resolver

# ------------------------------------------------------------------ parse


@pytest.mark.parametrize(
    ("url", "host"),
    [
        ("https://www.goodreads.com/book/show/4671", "www.goodreads.com"),
        ("http://books.example/", "books.example"),
        ("HTTPS://Example.COM./path", "example.com."),
        ("https://books.example:8443/x#reviews", "books.example"),
        ("http://bücher.example/", "bücher.example"),
    ],
)
def test_parse_accepts_http_and_https(url, host):
    assert parse(url).host == host


@pytest.mark.parametrize(
    "url",
    [
        "ftp://books.example/",
        "file:///etc/passwd",
        "javascript:alert(1)",
        "data:text/html,hi",
        "books.example/no-scheme",
        "http:///no-host",
        "http://user:secret@books.example/",
        "http://user@books.example/",
        "http://books.example:99999/",
        "http://[::1/",
    ],
)
def test_parse_rejects_what_the_service_will_not_fetch(url):
    with pytest.raises(InvalidUrl):
        parse(url)


# -------------------------------------------------------------- is_public


@pytest.mark.parametrize(
    "address",
    [
        "127.0.0.1",
        "10.1.2.3",
        "172.16.0.1",
        "192.168.1.1",
        "169.254.169.254",  # cloud metadata
        "100.64.0.1",  # carrier-grade NAT
        "0.0.0.0",
        "224.0.0.1",  # multicast
        "240.0.0.1",  # reserved
        "::1",
        "fe80::1",
        "fe80::1%eth0",
        "fc00::1",
        "::ffff:127.0.0.1",
        "2002:7f00:1::",  # 6to4 wrapping 127.0.0.1
    ],
)
def test_non_public_addresses(address):
    assert is_public(address) is False


@pytest.mark.parametrize("address", ["8.8.8.8", PUBLIC_ADDRESS, "2606:4700::1111"])
def test_public_addresses(address):
    assert is_public(address) is True


# ----------------------------------------------------------- HostChecker


@pytest.mark.anyio
async def test_a_public_host_passes_the_check():
    target = await HostChecker(resolver({})).check("https://books.example/b/1")
    assert (target.url, target.host) == ("https://books.example/b/1", "books.example")


@pytest.mark.anyio
async def test_a_private_host_is_invalid_naming_host_and_address():
    checker = HostChecker(resolver({"intranet.example": ["10.0.0.7"]}))
    with pytest.raises(InvalidUrl, match=r"intranet\.example.*10\.0\.0\.7"):
        await checker.check("http://intranet.example/")


@pytest.mark.anyio
async def test_one_private_address_among_public_ones_is_enough_to_refuse():
    checker = HostChecker(resolver({"mixed.example": [PUBLIC_ADDRESS, "192.168.0.10"]}))
    with pytest.raises(InvalidUrl, match="192.168.0.10"):
        await checker.check("https://mixed.example/")


@pytest.mark.anyio
@pytest.mark.parametrize(
    "answer",
    [OSError("boom"), socket.gaierror(socket.EAI_NONAME, "Name or service not known"), []],
)
async def test_a_failed_or_empty_lookup_is_unresolvable(answer):
    with pytest.raises(Unresolvable):
        await HostChecker(resolver({"gone.example": answer})).check("https://gone.example/")


@pytest.mark.anyio
async def test_a_host_the_resolver_cannot_encode_is_invalid_not_a_crash():
    checker = HostChecker(resolver({"bad.example": UnicodeError("label too long")}))
    with pytest.raises(InvalidUrl):
        await checker.check("https://bad.example/")


@pytest.mark.anyio
async def test_each_host_is_resolved_once_per_checker():
    dns = resolver({})
    checker = HostChecker(dns)
    await checker.check("https://books.example/a")
    await checker.check("https://books.example/b")
    assert await checker.non_public_address("books.example") is None
    assert dns.calls == ["books.example"]


@pytest.mark.anyio
async def test_separate_checkers_do_not_share_answers():
    dns = resolver({})
    await HostChecker(dns).check("https://books.example/")
    await HostChecker(dns).check("https://books.example/")
    assert dns.calls == ["books.example", "books.example"]


# ----------------------------- the real resolver, on hosts that need no DNS


@pytest.mark.anyio
@pytest.mark.parametrize(
    "url",
    [
        "http://127.0.0.1/",
        "http://[::1]/",
        "http://2130706433/",  # 127.0.0.1 as one decimal number
        "http://0x7f.1/",  # 127.0.0.1 in hex shorthand
        "http://[::ffff:127.0.0.1]/",
        "http://169.254.169.254/latest/meta-data/",
        "http://10.0.0.1:6379/",
    ],
)
async def test_ip_literals_in_any_encoding_are_refused(url):
    with pytest.raises(InvalidUrl):
        await HostChecker(system_resolver).check(url)


@pytest.mark.anyio
async def test_a_label_too_long_to_encode_is_invalid_without_any_lookup():
    with pytest.raises(InvalidUrl):
        await HostChecker(system_resolver).check("http://" + "a" * 64 + ".example/")
