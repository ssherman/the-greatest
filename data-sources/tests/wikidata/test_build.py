import gzip
import hashlib
import json

import httpx
import pytest
from typer.testing import CliRunner

from common.gates import GateResult
from wikidata.pipeline import build as build_module
from wikidata.pipeline.build import BuildFailed, app, build
from wikidata.pipeline.paths import TABLES, WikidataPaths
from wikidata.pipeline.versions import read_status

from .conftest import FIXTURES

runner = CliRunner()


def run_build(root, **kwargs):
    return build(
        root=root,
        dump=FIXTURES / "mini-all.json",
        dump_date="2026-11-05",
        redirect_sql=FIXTURES / "mini-redirect.sql",
        page_sql=FIXTURES / "mini-page.sql",
        memory_limit="1GB",
        threads=2,
        fixture=True,
        **kwargs,
    )


def test_the_fixture_build_writes_a_passing_manifest_and_all_six_tables(tmp_path):
    manifest = run_build(tmp_path)
    paths = WikidataPaths(root=tmp_path, dump_date="2026-11-05")
    on_disk = json.loads(paths.manifest_path.read_text())
    assert on_disk["gates_passed"] is True
    assert set(on_disk["tables"]) == set(TABLES) and manifest["tables"] == on_disk["tables"]
    assert on_disk["dump_date"] == "2026-11-05" and on_disk["pipeline_version"] >= 1
    assert all(paths.table(t).exists() for t in TABLES)
    assert not paths.staging_dir.exists()
    assert paths.report_path.exists()
    assert read_status(tmp_path).passing == ["2026-11-05"]


def test_a_gate_failure_keeps_report_and_failed_manifest_but_no_tables(tmp_path, monkeypatch):
    monkeypatch.setattr(
        build_module, "run_gates", lambda *a, **k: [GateResult("row_counts", "fail", "forced")]
    )
    with pytest.raises(BuildFailed):
        run_build(tmp_path)
    paths = WikidataPaths(root=tmp_path, dump_date="2026-11-05")
    assert json.loads(paths.manifest_path.read_text())["gates_passed"] is False
    report = json.loads(paths.report_path.read_text())
    assert [g["name"] for g in report["gates"] if g["status"] == "fail"] == ["row_counts"]
    assert list(paths.version_dir.rglob("*.parquet")) == []
    assert read_status(tmp_path).failed == ["2026-11-05"]

    result = runner.invoke(
        app,
        [
            "--root", str(tmp_path), "--dump", str(FIXTURES / "mini-all.json"),
            "--dump-date", "2026-11-06", "--redirect-sql", str(FIXTURES / "mini-redirect.sql"),
            "--page-sql", str(FIXTURES / "mini-page.sql"), "--memory-limit", "1GB",
            "--threads", "2", "--fixture",
        ],
    )  # fmt: skip
    assert result.exit_code == 1


def test_without_dump_it_discovers_downloads_and_deletes_the_dump(tmp_path):
    base = "https://dumps.wikimedia.org/wikidatawiki/"
    payload = (FIXTURES / "mini-all.json.gz").read_bytes()
    md5 = hashlib.md5(payload).hexdigest()

    def handler(request):
        url = str(request.url)
        if url == f"{base}entities/":
            return httpx.Response(200, text='<a href="20261102/">x</a>')
        if url == f"{base}entities/20261102/":
            return httpx.Response(200, text='<a href="wikidata-20261105-all.json.gz">x</a>')
        if url.endswith("md5sums.txt"):
            return httpx.Response(200, text=f"{md5}  wikidata-20261105-all.json.gz\n")
        if url.endswith("redirect.sql.gz"):
            return httpx.Response(
                200, content=gzip.compress((FIXTURES / "mini-redirect.sql").read_bytes())
            )
        if url.endswith("page.sql.gz"):
            return httpx.Response(
                200, content=gzip.compress((FIXTURES / "mini-page.sql").read_bytes())
            )
        if request.method == "HEAD":
            return httpx.Response(200, headers={"content-length": str(len(payload))})
        start, end = request.headers["range"].removeprefix("bytes=").split("-")
        return httpx.Response(206, content=payload[int(start) : int(end) + 1])

    with httpx.Client(transport=httpx.MockTransport(handler)) as client:
        manifest = build(root=tmp_path, memory_limit="1GB", threads=2, fixture=True, client=client)
    assert manifest["dump_date"] == "2026-11-05"
    assert not (tmp_path / "dumps" / "2026-11-05" / "wikidata-20261105-all.json.gz").exists()


def test_previous_counts_ignore_later_versions(tmp_path):
    for date, rows in (("2026-11-01", 10), ("2026-11-20", 99)):
        directory = tmp_path / "versions" / date
        directory.mkdir(parents=True)
        (directory / "manifest.json").write_text(
            json.dumps({"gates_passed": True, "tables": {"items": rows}})
        )
    assert build_module._previous_counts(tmp_path, "2026-11-05") == {"items": 10}
