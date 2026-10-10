import gzip
from pathlib import Path

import numpy as np
import pytest

from recommender.pairs import Pairs, build_matrix, read_pairs


def write_csv(path: Path, rows: list[tuple[int, int]], gz: bool = True) -> Path:
    text = "user_id,item_id\n" + "".join(f"{u},{i}\n" for u, i in rows)
    if gz:
        with gzip.open(path, "wt") as f:
            f.write(text)
    else:
        path.write_text(text)
    return path


def test_read_pairs_reads_gzipped_and_plain_csv(tmp_path):
    rows = [(1, 10), (1, 11), (2, 10)]
    for name, gz in (("a.csv.gz", True), ("b.csv", False)):
        pairs = read_pairs(write_csv(tmp_path / name, rows, gz=gz))
        assert pairs.user_ids.tolist() == [1, 1, 2]
        assert pairs.item_ids.tolist() == [10, 11, 10]
        assert pairs.user_ids.dtype == np.int64


def test_read_pairs_refuses_a_foreign_header(tmp_path):
    path = tmp_path / "x.csv"
    path.write_text("item_id,user_id\n1,2\n")
    with pytest.raises(ValueError, match="header"):
        read_pairs(path)


def test_build_matrix_applies_the_item_floor_then_the_user_floor_and_dedupes():
    # items: 10 has 3 readers, 11 has 2, 12 and 13 have 1 each. User 3 has only
    # item 13 and is empty after the item floor; user 4 has one positive left.
    pairs = Pairs(
        user_ids=np.array([1, 1, 2, 2, 3, 4, 4, 1]),
        item_ids=np.array([10, 11, 10, 11, 13, 10, 12, 10]),
    )
    m = build_matrix(pairs, min_readers=2, min_positives=2)
    assert m.item_index.tolist() == [10, 11]
    assert m.user_index.tolist() == [1, 2]
    assert m.X.shape == (2, 2)
    assert m.X.toarray().tolist() == [[1.0, 1.0], [1.0, 1.0]]
    assert m.X.dtype == np.float32


def test_build_matrix_keeps_a_single_positive_user_when_asked():
    pairs = Pairs(user_ids=np.array([1, 2, 2]), item_ids=np.array([10, 10, 11]))
    m = build_matrix(pairs, min_readers=1, min_positives=1)
    assert m.X.shape == (2, 2)
    assert m.X.sum() == 3
