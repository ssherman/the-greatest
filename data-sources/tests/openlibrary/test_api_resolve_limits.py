"""POST /resolve under load: a cap on how many run at once, and a deadline.

On 2026-10-06 four Goodreads imports resolving at once pinned the ol VM for
25 minutes: the client gave up at 60 s, the server kept every abandoned query
running, and each new one joined the pile. Beyond the cap the service answers
503 at once; past the deadline it interrupts the query and answers 504.
"""

from __future__ import annotations

import threading
import time

import duckdb
import pytest
from fastapi.testclient import TestClient

from openlibrary.api import resolve as resolve_module
from openlibrary.api.deps import Settings, open_artifact
from openlibrary.api.limits import Deadline
from openlibrary.api.main import create_app

# Runs for minutes unless something stops it.
SLOW_QUERY = "SELECT count(*) FROM range(100000000000)"


def _client(fixture_artifact, **settings):
    state = open_artifact(
        Settings(
            data_root=fixture_artifact.root, data_version=fixture_artifact.dump_date, **settings
        )
    )
    return TestClient(create_app(state))


def _a_query():
    return {"title": "Anything", "author_names": ["Someone"]}


def test_a_resolve_beyond_the_cap_is_answered_busy_at_once(fixture_artifact, monkeypatch):
    real_resolve = resolve_module.resolve
    started, release = threading.Event(), threading.Event()
    statuses = []

    def held(cur, state, request):
        started.set()
        release.wait(10)
        return real_resolve(cur, state, request)

    monkeypatch.setattr(resolve_module, "resolve", held)
    with _client(fixture_artifact, resolve_concurrency=1) as client:
        first = threading.Thread(
            target=lambda: statuses.append(client.post("/resolve", json=_a_query()).status_code)
        )
        first.start()
        try:
            assert started.wait(5)
            began = time.monotonic()
            response = client.post("/resolve", json=_a_query())
            elapsed = time.monotonic() - began
        finally:
            release.set()
            first.join(10)

    assert response.status_code == 503
    assert response.headers["retry-after"] == "2"
    # The Rails client tells busy from any other 503 by this prefix.
    assert response.json()["detail"].startswith("busy:")
    assert elapsed < 1
    assert statuses == [200]


def test_a_cap_of_two_admits_a_second_resolve(fixture_artifact, monkeypatch):
    real_resolve = resolve_module.resolve
    # Each resolve waits for the other to arrive: had the second been turned
    # away, the first would time out at the barrier and fail.
    both_in = threading.Barrier(2, timeout=5)
    statuses = []

    def held(cur, state, request):
        both_in.wait()
        return real_resolve(cur, state, request)

    monkeypatch.setattr(resolve_module, "resolve", held)
    with _client(fixture_artifact, resolve_concurrency=2) as client:
        threads = [
            threading.Thread(
                target=lambda: statuses.append(client.post("/resolve", json=_a_query()).status_code)
            )
            for _ in range(2)
        ]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(10)

    assert statuses == [200, 200]


def test_the_slot_is_free_again_once_a_resolve_finishes(fixture_artifact):
    with _client(fixture_artifact, resolve_concurrency=1) as client:
        statuses = [client.post("/resolve", json=_a_query()).status_code for _ in range(3)]

    assert statuses == [200, 200, 200]


def test_a_resolve_past_its_deadline_is_interrupted_and_answered_504(fixture_artifact, monkeypatch):
    def slow(cur, state, request):
        cur.execute(SLOW_QUERY).fetchall()

    monkeypatch.setattr(resolve_module, "resolve", slow)
    with _client(fixture_artifact, resolve_deadline_s=0.2) as client:
        began = time.monotonic()
        response = client.post("/resolve", json=_a_query())
        elapsed = time.monotonic() - began

    assert response.status_code == 504
    assert "deadline" in response.json()["detail"]
    assert elapsed < 3


def test_an_interrupted_resolve_gives_its_slot_back(fixture_artifact, monkeypatch):
    def slow(cur, state, request):
        cur.execute(SLOW_QUERY).fetchall()

    with _client(fixture_artifact, resolve_concurrency=1, resolve_deadline_s=0.2) as client:
        monkeypatch.setattr(resolve_module, "resolve", slow)
        timed_out = client.post("/resolve", json=_a_query())
        monkeypatch.undo()
        after = client.post("/resolve", json=_a_query())

    assert (timed_out.status_code, after.status_code) == (504, 200)


def test_a_deadline_that_passes_between_statements_still_stops_the_next_one():
    # /resolve runs a chain of statements; an interrupt sent while none is
    # running is a no-op, so the deadline has to keep interrupting.
    con = duckdb.connect()
    cur = con.cursor()
    began = time.monotonic()
    with pytest.raises(duckdb.InterruptException), Deadline(cur, seconds=0.1) as deadline:
        time.sleep(0.3)
        cur.execute(SLOW_QUERY).fetchall()

    assert deadline.expired
    assert time.monotonic() - began < 3
    con.close()


def test_a_deadline_that_never_passes_interrupts_nothing():
    con = duckdb.connect()
    cur = con.cursor()
    with Deadline(cur, seconds=5) as deadline:
        assert cur.execute("SELECT 42").fetchone() == (42,)

    assert not deadline.expired
    assert cur.execute("SELECT 1").fetchone() == (1,)
    con.close()


def test_threads_is_set_on_the_connection(fixture_artifact):
    settings = Settings(
        data_root=fixture_artifact.root, data_version=fixture_artifact.dump_date, threads=3
    )
    state = open_artifact(settings)
    try:
        assert state.connection.execute("SELECT current_setting('threads')").fetchone() == (3,)
    finally:
        state.connection.close()
