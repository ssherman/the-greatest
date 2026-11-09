import json

from typer.testing import CliRunner

from wikidata.pipeline.versions import (
    VersionStatus,
    app,
    decide,
    prune,
    prune_before,
    read_status,
)

runner = CliRunner()


def make(root, date, passed=None):
    directory = root / "versions" / date
    directory.mkdir(parents=True)
    if passed is not None:
        (directory / "manifest.json").write_text(json.dumps({"gates_passed": passed}))
    return directory


def test_a_version_without_a_manifest_is_neither_passing_nor_failed(tmp_path):
    make(tmp_path, "2026-11-05")
    status = read_status(tmp_path)
    assert (status.passing, status.failed) == ([], [])
    assert status.incomplete == ["2026-11-05"]


def test_passing_and_failed_are_read_from_manifests(tmp_path):
    make(tmp_path, "2026-10-29", True)
    make(tmp_path, "2026-11-05", False)
    status = read_status(tmp_path)
    assert status.passing == ["2026-10-29"]
    assert status.failed == ["2026-11-05"]


def test_next_action_skips_a_date_already_passed_or_failed():
    status = VersionStatus(passing=["2026-11-05"], failed=["2026-11-12"], incomplete=[])
    assert decide("2026-11-05", status) == "skip built 2026-11-05"
    assert decide("2026-11-12", status) == "skip failed 2026-11-12"
    assert decide("2026-11-19", status) == "build 2026-11-19"


def test_status_command_prints_json(tmp_path):
    make(tmp_path, "2026-10-29", True)
    result = runner.invoke(app, ["status", "--root", str(tmp_path)])
    assert json.loads(result.output) == {
        "passing": ["2026-10-29"],
        "failed": [],
        "incomplete": [],
    }


def test_prune_keeps_the_current_and_the_newest(tmp_path):
    for date in ("2026-10-15", "2026-10-22", "2026-10-29", "2026-11-05"):
        make(tmp_path, date, True)
    removed = prune(tmp_path, keep=1, current="2026-10-22")
    assert sorted(p.name for p in removed) == ["2026-10-15", "2026-10-29"]
    assert sorted(d.name for d in (tmp_path / "versions").iterdir()) == ["2026-10-22", "2026-11-05"]


def test_prune_drops_a_superseded_dump_directory(tmp_path):
    make(tmp_path, "2026-11-05", True)
    (tmp_path / "dumps" / "2026-11-05").mkdir(parents=True)
    (tmp_path / "dumps" / "2026-11-12").mkdir(parents=True)
    prune(tmp_path, keep=2, current=None)
    assert [d.name for d in (tmp_path / "dumps").iterdir()] == ["2026-11-12"]


def test_prune_before_clears_the_dumps_and_dead_versions_of_earlier_weeks(tmp_path):
    make(tmp_path, "2026-10-22", True)
    make(tmp_path, "2026-10-29", False)  # a failed build whose 157 GB dump was never pruned
    make(tmp_path, "2026-11-05")  # an OOM-killed build: no manifest
    make(tmp_path, "2026-11-12", False)
    for date in ("2026-10-29", "2026-11-05", "2026-11-12"):
        (tmp_path / "dumps" / date).mkdir(parents=True)
        (tmp_path / "dumps" / date / "wikidatawiki-latest-redirect.sql.gz").write_bytes(b"x")
    removed = prune_before(tmp_path, "2026-11-12")
    assert sorted(p.parent.name + "/" + p.name for p in removed) == [
        "dumps/2026-10-29",
        "dumps/2026-11-05",
        "versions/2026-10-29",
        "versions/2026-11-05",
    ]
    assert sorted(d.name for d in (tmp_path / "versions").iterdir()) == ["2026-10-22", "2026-11-12"]
    assert [d.name for d in (tmp_path / "dumps").iterdir()] == ["2026-11-12"]


def test_prune_before_never_touches_a_passing_or_the_served_version(tmp_path):
    make(tmp_path, "2026-10-22", True)
    make(tmp_path, "2026-10-29", True)
    make(tmp_path, "2026-11-05", False)
    removed = prune_before(tmp_path, "2026-11-12", current="2026-11-05")
    assert [p.name for p in removed] == []
    assert len(list((tmp_path / "versions").iterdir())) == 3


def test_prune_before_command_runs_only_that_step(tmp_path):
    make(tmp_path, "2026-10-22", True)
    make(tmp_path, "2026-11-05")
    result = runner.invoke(
        app, ["prune", "--root", str(tmp_path), "--keep", "1", "--before", "2026-11-12"]
    )
    assert result.exit_code == 0
    assert sorted(d.name for d in (tmp_path / "versions").iterdir()) == ["2026-10-22"]


def test_prune_drops_superseded_failed_and_incomplete_directories(tmp_path):
    make(tmp_path, "2026-10-22", False)
    make(tmp_path, "2026-10-29")
    make(tmp_path, "2026-11-05", True)
    make(tmp_path, "2026-11-12", False)
    prune(tmp_path, keep=2, current=None)
    assert sorted(d.name for d in (tmp_path / "versions").iterdir()) == ["2026-11-05", "2026-11-12"]
