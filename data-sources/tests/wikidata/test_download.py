import hashlib
import re

import httpx
import pytest

from wikidata.pipeline import download as dl
from wikidata.pipeline.download import DownloadError, Dump, discover_latest, download

BASE = "https://dumps.wikimedia.org/wikidatawiki/entities/"
PAYLOAD = bytes(range(256)) * 40  # 10,240 bytes


def listing_handler(request: httpx.Request) -> httpx.Response:
    url = str(request.url)
    if url == BASE:
        return httpx.Response(
            200, text='<a href="20261109/">x</a><a href="20261102/">x</a><a href="20261026/">x</a>'
        )
    if url == f"{BASE}20261109/":  # lexemes only
        return httpx.Response(200, text='<a href="wikidata-20261109-lexemes.json.gz">x</a>')
    if url == f"{BASE}20261102/":
        return httpx.Response(
            200,
            text='<a href="wikidata-20261105-all.json.gz">x</a>'
            '<a href="wikidata-20261105-md5sums.txt">x</a>',
        )
    if url == f"{BASE}20261102/wikidata-20261105-md5sums.txt":
        return httpx.Response(
            200,
            text="abc123  wikidata-20261105-all.json.gz\nffff  wikidata-20261105-lexemes.json.gz\n",
        )
    return httpx.Response(404)


def test_discover_latest_uses_the_file_date_and_skips_lexeme_only_directories():
    with httpx.Client(transport=httpx.MockTransport(listing_handler)) as client:
        dump = discover_latest(client)
    assert dump == Dump(
        dump_date="2026-11-05",
        url=f"{BASE}20261102/wikidata-20261105-all.json.gz",
        md5="abc123",
    )


class RangeServer:
    def __init__(self, payload=PAYLOAD):
        self.payload = payload
        self.ranges: list[tuple[int, int]] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        if request.method == "HEAD":
            return httpx.Response(200, headers={"content-length": str(len(self.payload))})
        start, end = map(int, re.fullmatch(r"bytes=(\d+)-(\d+)", request.headers["range"]).groups())
        self.ranges.append((start, end))
        return httpx.Response(206, content=self.payload[start : end + 1])


def dump_for(payload=PAYLOAD, md5=None):
    return Dump(
        "2026-11-05",
        f"{BASE}20261102/wikidata-20261105-all.json.gz",
        md5 or hashlib.md5(payload).hexdigest(),
    )


def test_two_parts_use_disjoint_ranges_and_join_in_order(tmp_path):
    server = RangeServer()
    with httpx.Client(transport=httpx.MockTransport(server)) as client:
        path = download(dump_for(), tmp_path, client=client)
    assert path.read_bytes() == PAYLOAD
    assert sorted(server.ranges) == [(0, 5119), (5120, 10239)]
    assert list(tmp_path.glob("*.part*")) == []


def test_a_short_part_file_resumes_with_a_range_request(tmp_path):
    name = "wikidata-20261105-all.json.gz"
    (tmp_path / f"{name}.part0").write_bytes(PAYLOAD[:1000])
    server = RangeServer()
    with httpx.Client(transport=httpx.MockTransport(server)) as client:
        path = download(dump_for(), tmp_path, client=client)
    assert path.read_bytes() == PAYLOAD
    assert (1000, 5119) in server.ranges


def test_more_than_two_connections_is_refused(tmp_path):
    with (
        httpx.Client(transport=httpx.MockTransport(RangeServer())) as client,
        pytest.raises(ValueError),
    ):
        download(dump_for(), tmp_path, client=client, connections=3)


def test_a_bad_md5_raises_and_leaves_no_file(tmp_path):
    with (
        httpx.Client(transport=httpx.MockTransport(RangeServer())) as client,
        pytest.raises(DownloadError),
    ):
        download(dump_for(md5="0" * 32), tmp_path, client=client)
    assert list(tmp_path.iterdir()) == []


def test_redirect_sources_come_from_the_latest_directory(tmp_path):
    def handler(request):
        return httpx.Response(
            200,
            content=request.url.path.encode(),
            headers={"last-modified": "Sun, 01 Nov 2026 03:00:00 GMT"},
        )

    with httpx.Client(transport=httpx.MockTransport(handler)) as client:
        redirect, page, redirects_date = dl.download_redirect_sources(tmp_path, client=client)
    assert redirect.name == "wikidatawiki-latest-redirect.sql.gz"
    assert page.name == "wikidatawiki-latest-page.sql.gz"
    assert redirects_date == "2026-11-01"
    assert b"redirect" in redirect.read_bytes() and b"page" in page.read_bytes()


def test_a_verified_existing_dump_is_returned_without_any_request(tmp_path):
    (tmp_path / "wikidata-20261105-all.json.gz").write_bytes(PAYLOAD)

    def no_requests(request):
        raise AssertionError(f"unexpected request {request.url}")

    with httpx.Client(transport=httpx.MockTransport(no_requests)) as client:
        path = download(dump_for(), tmp_path, client=client)
    assert path.read_bytes() == PAYLOAD


def test_a_corrupt_existing_dump_is_deleted_and_refetched(tmp_path):
    (tmp_path / "wikidata-20261105-all.json.gz").write_bytes(b"junk")
    with httpx.Client(transport=httpx.MockTransport(RangeServer())) as client:
        path = download(dump_for(), tmp_path, client=client)
    assert path.read_bytes() == PAYLOAD
