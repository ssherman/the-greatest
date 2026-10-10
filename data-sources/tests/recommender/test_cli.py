import gzip
import json
from pathlib import Path

from typer.testing import CliRunner

from recommender import store
from recommender.cli import app

runner = CliRunner()

ROWS = [
    (1, 10),
    (1, 11),
    (1, 12),
    (1, 13),
    (1, 14),
    (2, 10),
    (2, 11),
    (2, 12),
    (2, 13),
    (2, 15),
    (3, 10),
    (3, 11),
    (3, 12),
    (3, 14),
    (3, 15),
    (4, 13),
    (4, 14),
    (4, 15),
    (4, 16),
    (4, 10),
    (5, 13),
    (5, 14),
    (5, 15),
    (5, 16),
    (5, 11),
    (6, 10),
    (6, 12),
    (6, 16),
    (6, 14),
    (6, 13),
]


def export(path: Path, rows=ROWS) -> Path:
    with gzip.open(path, "wt") as f:
        f.write("user_id,item_id\n" + "".join(f"{u},{i}\n" for u, i in rows))
    return path


def read_model(path: Path):
    with gzip.open(path, "rt") as f:
        lines = f.read().splitlines()
    assert lines[0] == "item_id,neighbor_id,weight"
    return [(int(a), int(b), float(c)) for a, b, c in (line.split(",") for line in lines[1:])]


def test_train_writes_a_sorted_model_and_a_manifest(tmp_path: Path):
    src = export(tmp_path / "2026-10-09.csv.gz")
    out = tmp_path / "model"
    result = runner.invoke(
        app,
        [
            "train",
            "--input",
            str(src),
            "--output-dir",
            str(out),
            "--name",
            "2026-10-09",
            "--lambda",
            "1",
            "--min-readers",
            "2",
            "--top-k",
            "3",
            "--eval-seed",
            "1",
        ],
    )
    assert result.exit_code == 0, result.output
    rows = read_model(out / "2026-10-09.csv.gz")
    assert rows == sorted(rows, key=lambda r: (r[0], -r[2]))
    assert all(w > 0 for _, _, w in rows)
    assert max(sum(1 for r in rows if r[0] == i) for i in {r[0] for r in rows}) <= 3
    manifest = json.loads((out / "2026-10-09.json").read_text())
    assert manifest["rows"] == len(rows)
    assert manifest["export"] == "2026-10-09" and manifest["lambda"] == 1.0
    assert manifest["items"] == 7 and manifest["users"] == 6
    assert 0.0 <= manifest["eval"]["hit_at_10"] <= 1.0
    assert "hit@10" in result.output


def test_run_pulls_latest_trains_pushes_and_moves_the_pointer(tmp_path: Path):
    root = tmp_path / "store"
    s = store.Local(root)
    s.put(
        store.interactions_key("books", "2026-10-09"), (export(tmp_path / "e.csv.gz")).read_bytes()
    )
    s.write_pointer(store.interactions_latest("books"), "2026-10-09")
    work = tmp_path / "work"
    result = runner.invoke(
        app,
        [
            "run",
            "--store-dir",
            str(root),
            "--work-dir",
            str(work),
            "--lambda",
            "1",
            "--min-readers",
            "2",
            "--top-k",
            "3",
            "--max-export-age-days",
            "100000",
        ],
    )
    assert result.exit_code == 0, result.output
    assert s.read_pointer(store.model_latest("books")) == "2026-10-09"
    assert s.exists(store.model_key("books", "2026-10-09"))
    manifest = json.loads(s.get(store.manifest_key("books", "2026-10-09")))
    assert manifest["previous"] is None

    again = runner.invoke(
        app,
        [
            "run",
            "--store-dir",
            str(root),
            "--work-dir",
            str(work),
            "--max-export-age-days",
            "100000",
        ],
    )
    assert again.exit_code == 0 and "already trained" in again.output


def test_run_keeps_the_pointer_when_the_gate_fails(tmp_path: Path):
    root = tmp_path / "store"
    s = store.Local(root)
    s.put(
        store.interactions_key("books", "2026-10-09"), (export(tmp_path / "e.csv.gz")).read_bytes()
    )
    s.write_pointer(store.interactions_latest("books"), "2026-10-09")
    s.put(
        store.manifest_key("books", "2026-10-01"), json.dumps({"eval": {"hit_at_10": 1.0}}).encode()
    )
    s.write_pointer(store.model_latest("books"), "2026-10-01")
    # Toy arithmetic: 7 items, 4 left on each shelf after the hold-out, so at most 3
    # candidates and the held book is always in the top 10 -> the new hit@10 is 1.0, which
    # passes the default 0.9 x 1.0 gate. A ratio above 1 makes the gate fail deterministically.
    result = runner.invoke(
        app,
        [
            "run",
            "--store-dir",
            str(root),
            "--work-dir",
            str(tmp_path / "w"),
            "--lambda",
            "1",
            "--min-readers",
            "2",
            "--top-k",
            "3",
            "--max-export-age-days",
            "100000",
            "--gate-ratio",
            "1.1",
        ],
    )
    assert result.exit_code == 1
    assert "below" in result.output
    assert s.read_pointer(store.model_latest("books")) == "2026-10-01"
    assert s.exists(store.model_key("books", "2026-10-09")), "the files stay for inspection"


def test_run_refuses_a_stale_export(tmp_path: Path):
    root = tmp_path / "store"
    s = store.Local(root)
    s.put(
        store.interactions_key("books", "2020-01-01"), (export(tmp_path / "e.csv.gz")).read_bytes()
    )
    s.write_pointer(store.interactions_latest("books"), "2020-01-01")
    result = runner.invoke(
        app, ["run", "--store-dir", str(root), "--work-dir", str(tmp_path / "w")]
    )
    assert result.exit_code == 1
    assert "older than" in result.output
