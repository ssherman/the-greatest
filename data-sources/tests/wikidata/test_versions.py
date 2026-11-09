import json

from typer.testing import CliRunner

from wikidata.pipeline.versions import VersionStatus, app, decide, prune, read_status

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


def test_prune_drops_superseded_failed_and_incomplete_directories(tmp_path):
    make(tmp_path, "2026-10-22", False)
    make(tmp_path, "2026-10-29")
    make(tmp_path, "2026-11-05", True)
    make(tmp_path, "2026-11-12", False)
    prune(tmp_path, keep=2, current=None)
    assert sorted(d.name for d in (tmp_path / "versions").iterdir()) == ["2026-11-05", "2026-11-12"]
