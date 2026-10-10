"""The trainer's own measurement (spec 2 §8.1): hide one positive per user
with enough history, fit on the rest, and ask whether it comes back in the
top 10 and top 50. This tunes λ, the reader floor and k where the model is
built; the Rails harness measures the fused page and owns the bar."""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np
import scipy.sparse as sp


@dataclass(frozen=True)
class Split:
    train: sp.csr_matrix
    users: np.ndarray
    held: np.ndarray


def hold_one_out(X: sp.csr_matrix, seed: int, min_positives: int = 5) -> Split:
    X = X.tocsr(copy=True)
    X.sort_indices()
    counts = np.diff(X.indptr)
    users = np.flatnonzero(counts >= min_positives).astype(np.int64)
    rng = np.random.default_rng(seed)
    positions = np.array(
        [rng.integers(X.indptr[u], X.indptr[u + 1]) for u in users], dtype=np.int64
    )
    held = X.indices[positions].astype(np.int64) if len(users) else np.empty(0, dtype=np.int64)
    train = X.copy()
    train.data[positions] = 0
    train.eliminate_zeros()
    return Split(train=train, users=users, held=held)


def metrics(
    train: sp.csr_matrix,
    model: sp.csr_matrix,
    users: np.ndarray,
    held: np.ndarray,
    k_hit: int = 10,
    k_recall: int = 50,
    batch: int = 2000,
) -> dict:
    if len(users) == 0:
        return {"users": 0, "hit_at_10": 0.0, "recall_at_50": 0.0}
    n_items = train.shape[1]
    k = min(k_recall, n_items)
    hits = 0
    recalls = 0
    for start in range(0, len(users), batch):
        rows = users[start : start + batch]
        shelf = train[rows]
        scores = (shelf @ model).toarray()
        scores[shelf.toarray() > 0] = -np.inf
        if k < n_items:
            top = np.argpartition(-scores, k - 1, axis=1)[:, :k]
        else:
            top = np.tile(np.arange(n_items), (len(rows), 1))
        order = np.argsort(-np.take_along_axis(scores, top, axis=1), axis=1, kind="stable")
        top = np.take_along_axis(top, order, axis=1)
        target = held[start : start + batch][:, None]
        hits += int(np.any(top[:, :k_hit] == target, axis=1).sum())
        recalls += int(np.any(top == target, axis=1).sum())
    return {
        "users": int(len(users)),
        "hit_at_10": hits / len(users),
        "recall_at_50": recalls / len(users),
    }
