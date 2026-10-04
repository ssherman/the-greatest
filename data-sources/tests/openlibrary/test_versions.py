import json
from pathlib import Path

from typer.testing import CliRunner

from openlibrary.pipeline import versions
from openlibrary.pipeline.download import DumpDateMismatch
from openlibrary.pipeline.versions import VersionStatus, decide, prune, read_status


def _version(root: Path, date: str, *, gates_passed: bool | None) -> Path:
    """gates_passed None = a build that never wrote its manifest."""
    directory = root / "versions" / date
    (directory / "_staging").mkdir(parents=True)
    if gates_passed is not None:
        (directory / "manifest.json").write_text(json.dumps({"gates_passed": gates_passed}))
    return directory


def _dumps(root: Path, date: str) -> Path:
    directory = root / "dumps" / date
    directory.mkdir(parents=True)
    (directory / "ol_dump_works_x.txt.gz").write_text("x")
    return directory


def test_status_sorts_versions_by_what_their_manifest_says(tmp_path):
    _version(tmp_path, "2026-08-31", gates_passed=True)
    _version(tmp_path, "2026-07-31", gates_passed=True)
    _version(tmp_path, "2026-09-30", gates_passed=False)
    _version(tmp_path, "2026-10-31", gates_passed=None)

    status = read_status(tmp_path)

    assert status.passing == ["2026-07-31", "2026-08-31"]
    assert status.failed == ["2026-09-30"]
    assert status.incomplete == ["2026-10-31"]


def test_an_unreadable_manifest_is_incomplete_so_it_is_rebuilt_not_trusted(tmp_path):
    directory = _version(tmp_path, "2026-08-31", gates_passed=None)
    (directory / "manifest.json").write_text("{not json")

    assert read_status(tmp_path).incomplete == ["2026-08-31"]


def test_status_of_an_empty_root_is_empty(tmp_path):
    assert read_status(tmp_path) == VersionStatus(passing=[], failed=[], incomplete=[])


def test_decide_builds_a_new_date_and_skips_one_already_tried():
    status = VersionStatus(passing=["2026-08-31"], failed=["2026-09-30"], incomplete=["2026-10-31"])

    assert decide("2026-08-31", status) == "skip built 2026-08-31"
    assert decide("2026-09-30", status) == "skip failed 2026-09-30"
    assert decide("2026-10-31", status) == "build 2026-10-31"
    assert decide("2026-11-30", status) == "build 2026-11-30"


def test_prune_keeps_the_newest_passing_versions_and_the_current_one(tmp_path):
    for date in ("2026-06-30", "2026-07-31", "2026-08-31", "2026-09-30"):
        _version(tmp_path, date, gates_passed=True)

    removed = prune(tmp_path, keep=2, current="2026-06-30")

    left = sorted(p.name for p in (tmp_path / "versions").iterdir())
    assert left == ["2026-06-30", "2026-08-31", "2026-09-30"]
    assert removed == [tmp_path / "versions" / "2026-07-31"]


def test_prune_keeps_a_failed_build_until_a_newer_date_builds(tmp_path):
    _version(tmp_path, "2026-08-31", gates_passed=True)
    _version(tmp_path, "2026-09-30", gates_passed=False)

    prune(tmp_path, keep=2, current="2026-08-31")
    assert (tmp_path / "versions" / "2026-09-30").exists()

    _version(tmp_path, "2026-10-31", gates_passed=True)
    prune(tmp_path, keep=2, current="2026-10-31")
    assert not (tmp_path / "versions" / "2026-09-30").exists()


def test_prune_drops_an_older_failed_date_when_a_newer_one_also_fails(tmp_path):
    _version(tmp_path, "2026-08-31", gates_passed=True)
    _version(tmp_path, "2026-09-30", gates_passed=False)
    _version(tmp_path, "2026-10-31", gates_passed=False)
    _dumps(tmp_path, "2026-09-30")
    _dumps(tmp_path, "2026-10-31")

    prune(tmp_path, keep=2, current="2026-08-31")

    assert not (tmp_path / "versions" / "2026-09-30").exists()
    assert (tmp_path / "versions" / "2026-10-31").exists()
    assert sorted(p.name for p in (tmp_path / "dumps").iterdir()) == ["2026-10-31"]


def test_prune_removes_a_superseded_incomplete_version(tmp_path):
    _version(tmp_path, "2026-08-31", gates_passed=None)
    _version(tmp_path, "2026-09-30", gates_passed=True)

    prune(tmp_path, keep=2, current="2026-09-30")

    assert not (tmp_path / "versions" / "2026-08-31").exists()


def test_a_manifest_that_is_not_an_object_is_incomplete(tmp_path):
    directory = _version(tmp_path, "2026-08-31", gates_passed=None)
    (directory / "manifest.json").write_text("[]")

    assert read_status(tmp_path).incomplete == ["2026-08-31"]


def test_prune_drops_dumps_once_their_date_is_built_or_superseded(tmp_path):
    _version(tmp_path, "2026-08-31", gates_passed=True)
    _version(tmp_path, "2026-09-30", gates_passed=False)
    _dumps(tmp_path, "2026-07-31")
    _dumps(tmp_path, "2026-08-31")
    _dumps(tmp_path, "2026-09-30")

    removed = prune(tmp_path, keep=2, current="2026-08-31")

    assert tmp_path / "dumps" / "2026-07-31" in removed
    assert tmp_path / "dumps" / "2026-08-31" in removed
    # 09-30 failed and is newer than anything passing: its dumps stay for a retry.
    assert sorted(p.name for p in (tmp_path / "dumps").iterdir()) == ["2026-09-30"]


def test_next_action_prints_the_decision(tmp_path, monkeypatch):
    _version(tmp_path, "2026-08-31", gates_passed=True)
    monkeypatch.setattr(versions, "discover_all_dump_dates", lambda client: {"works": "2026-08-31"})

    result = CliRunner().invoke(versions.app, ["next-action", "--root", str(tmp_path)])

    assert result.exit_code == 0
    assert result.stdout.strip() == "skip built 2026-08-31"


def test_next_action_reports_a_mismatch_as_a_skip(tmp_path, monkeypatch):
    def mismatch(client):
        raise DumpDateMismatch("dumps resolve to more than one date: {...}")

    monkeypatch.setattr(versions, "discover_all_dump_dates", mismatch)

    result = CliRunner().invoke(versions.app, ["next-action", "--root", str(tmp_path)])

    assert result.exit_code == 0
    assert result.stdout.startswith("skip mismatch ")


def test_next_action_fails_when_open_library_cannot_be_asked(tmp_path, monkeypatch):
    import httpx

    def unreachable(client):
        raise httpx.ConnectError("no route")

    monkeypatch.setattr(versions, "discover_all_dump_dates", unreachable)

    result = CliRunner().invoke(versions.app, ["next-action", "--root", str(tmp_path)])

    assert result.exit_code != 0


def test_status_and_prune_commands(tmp_path):
    _version(tmp_path, "2026-07-31", gates_passed=True)
    _version(tmp_path, "2026-08-31", gates_passed=True)
    runner = CliRunner()

    status = runner.invoke(versions.app, ["status", "--root", str(tmp_path)])
    assert json.loads(status.stdout) == {
        "passing": ["2026-07-31", "2026-08-31"],
        "failed": [],
        "incomplete": [],
    }

    pruned = runner.invoke(versions.app, ["prune", "--root", str(tmp_path), "--keep", "1"])
    assert pruned.exit_code == 0
    assert pruned.stdout.strip() == str(tmp_path / "versions" / "2026-07-31")
