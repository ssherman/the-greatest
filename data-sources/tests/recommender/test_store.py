from pathlib import Path

import pytest
from botocore.exceptions import ClientError

from recommender import store
from recommender.store import R2, Local, Missing


def test_keys_match_the_rails_side():
    assert (
        store.interactions_key("books", "2026-10-09")
        == "recommendations/books/interactions/2026-10-09.csv.gz"
    )
    assert store.interactions_latest("books") == "recommendations/books/interactions/latest"
    assert store.model_key("books", "v") == "recommendations/books/model/v.csv.gz"
    assert store.manifest_key("books", "v") == "recommendations/books/model/v.json"
    assert store.model_latest("books") == "recommendations/books/model/latest"


def test_local_round_trip(tmp_path: Path):
    s = Local(tmp_path)
    assert not s.exists("a/b")
    assert s.read_pointer("a/latest") is None
    with pytest.raises(Missing):
        s.get("a/b")
    s.put("a/b", b"\x00bytes")
    assert s.exists("a/b") and s.get("a/b") == b"\x00bytes"
    s.write_pointer("a/latest", "b")
    assert s.read_pointer("a/latest") == "b"
    assert (tmp_path / "a/latest").read_text() == "b\n"


class FakeClient:
    def __init__(self):
        self.objects: dict[tuple[str, str], bytes] = {}

    def put_object(self, Bucket, Key, Body):
        self.objects[(Bucket, Key)] = Body

    def get_object(self, Bucket, Key):
        if (Bucket, Key) not in self.objects:
            raise ClientError({"Error": {"Code": "NoSuchKey"}}, "GetObject")
        import io

        return {"Body": io.BytesIO(self.objects[(Bucket, Key)])}

    def head_object(self, Bucket, Key):
        if (Bucket, Key) not in self.objects:
            raise ClientError({"Error": {"Code": "404"}}, "HeadObject")
        return {}


def test_r2_uses_the_bucket_and_translates_missing_keys():
    client = FakeClient()
    s = R2(client, "tg-recs")
    assert not s.exists("k")
    assert s.read_pointer("k") is None
    with pytest.raises(Missing):
        s.get("k")
    s.put("k", b"v")
    assert client.objects[("tg-recs", "k")] == b"v"
    assert s.exists("k") and s.get("k") == b"v"
    s.write_pointer("p", "x")
    assert s.read_pointer("p") == "x"


def test_r2_from_env_requires_all_four(monkeypatch):
    for key in R2.ENV_KEYS:
        monkeypatch.delenv(key, raising=False)
    assert R2.from_env() is None
    monkeypatch.setenv("RECOMMENDER_R2_ACCOUNT_ID", "acct")
    with pytest.raises(RuntimeError, match="RECOMMENDER_R2"):
        R2.from_env()
