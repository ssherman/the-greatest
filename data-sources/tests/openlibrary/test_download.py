import httpx
import pytest

from openlibrary.pipeline.download import (
    DUMP_KINDS,
    DumpDateMismatch,
    discover_all_dump_dates,
    discover_dump_date,
    latest_url,
)

ARCHIVE = "https://ia800708.us.archive.org/27/items/ol_dump_{d}/ol_dump_{k}_{d}.txt.gz"


def _client(dates: dict[str, str]) -> httpx.Client:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, request=request)

    def redirecting(request: httpx.Request) -> httpx.Response:
        name = request.url.path.rsplit("/", 1)[-1]
        if name.endswith("_latest.txt.gz"):
            kind = name.removeprefix("ol_dump_").removesuffix("_latest.txt.gz")
            return httpx.Response(302, headers={"location": ARCHIVE.format(d=dates[kind], k=kind)})
        return handler(request)

    return httpx.Client(transport=httpx.MockTransport(redirecting), follow_redirects=True)


def test_six_dump_kinds_with_reading_log_hyphenated():
    assert DUMP_KINDS == ("works", "authors", "editions", "redirects", "ratings", "reading-log")
    assert latest_url("reading-log").endswith("ol_dump_reading-log_latest.txt.gz")


def test_dump_date_is_discovered_from_the_redirect_target():
    with _client({k: "2026-07-31" for k in DUMP_KINDS}) as client:
        assert discover_dump_date(client, "works") == "2026-07-31"


def test_all_six_dates_agreeing_returns_one_date():
    with _client({k: "2026-07-31" for k in DUMP_KINDS}) as client:
        assert set(discover_all_dump_dates(client).values()) == {"2026-07-31"}


def test_mismatched_dates_raise_rather_than_building_a_frankenstein_artifact():
    dates = {k: "2026-07-31" for k in DUMP_KINDS}
    dates["editions"] = "2026-06-30"
    with _client(dates) as client, pytest.raises(DumpDateMismatch) as exc:
        discover_all_dump_dates(client)
    assert "editions" in str(exc.value)
