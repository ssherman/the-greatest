"""The export file in, a binary user×item matrix out (spec 2 §4.2).

The item floor runs first (a book needs min_readers readers to be worth a
column), then the user floor (a one-book row teaches nothing and inflates the
diagonal). One pass each, documented: a second item pass after the user pass
would move the floor by a handful of books and is not worth the surprise.
"""

from __future__ import annotations

import csv
import gzip
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import scipy.sparse as sp

HEADER = ["user_id", "item_id"]


@dataclass(frozen=True)
class Pairs:
    user_ids: np.ndarray
    item_ids: np.ndarray


@dataclass(frozen=True)
class Matrix:
    X: sp.csr_matrix
    item_index: np.ndarray
    user_index: np.ndarray


def read_pairs(path: Path) -> Pairs:
    opener = gzip.open if str(path).endswith(".gz") else open
    with opener(path, "rt", newline="") as handle:
        reader = csv.reader(handle)
        header = next(reader, None)
        if header != HEADER:
            raise ValueError(f"{path}: expected header {HEADER}, got {header}")
        rows = np.array([(int(u), int(i)) for u, i in reader], dtype=np.int64).reshape(-1, 2)
    return Pairs(user_ids=rows[:, 0], item_ids=rows[:, 1])


def build_matrix(pairs: Pairs, min_readers: int, min_positives: int = 2) -> Matrix:
    stacked = np.unique(np.stack([pairs.user_ids, pairs.item_ids], axis=1), axis=0)
    users, items = stacked[:, 0], stacked[:, 1]

    item_vals, item_counts = np.unique(items, return_counts=True)
    keep = np.isin(items, item_vals[item_counts >= min_readers])
    users, items = users[keep], items[keep]

    user_vals, user_counts = np.unique(users, return_counts=True)
    keep = np.isin(users, user_vals[user_counts >= min_positives])
    users, items = users[keep], items[keep]

    item_index, item_codes = np.unique(items, return_inverse=True)
    user_index, user_codes = np.unique(users, return_inverse=True)
    X = sp.csr_matrix(
        (np.ones(len(users), dtype=np.float32), (user_codes, item_codes)),
        shape=(len(user_index), len(item_index)),
    )
    return Matrix(X=X, item_index=item_index, user_index=user_index)
