"""EASE (Steck, 2019): one closed-form solve over the item gram matrix.

    G = XᵀX + λI,  P = G⁻¹,  B = −P / diag(P),  diag(B) = 0
    score(u, j) = Σ_i X[u, i] · B[i, j]

Pure numpy/scipy, no I/O. Memory is the gram matrix plus the inverse: at
18k items in float64 about 2.6 GB each, which is why the home server runs
this with a 14 GB limit and why the matrix is built in place.
"""

from __future__ import annotations

import numpy as np
import scipy.linalg
import scipy.sparse as sp


def fit(X: sp.csr_matrix, lam: float) -> np.ndarray:
    G = (X.T @ X).toarray().astype(np.float64)
    n = G.shape[0]
    G[np.diag_indices(n)] += lam
    P = scipy.linalg.inv(G, overwrite_a=True, check_finite=False)
    diag = np.diag(P).copy()
    P /= -diag[None, :]
    np.fill_diagonal(P, 0.0)
    return P


def top_neighbors(B: np.ndarray, k: int) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Per row, the k largest positive weights, weight descending (row = the shelf
    book, column = where it leads). Rows with no positive weight contribute nothing."""
    n = B.shape[0]
    out_rows: list[np.ndarray] = []
    out_cols: list[np.ndarray] = []
    out_weights: list[np.ndarray] = []
    for i in range(n):
        row = B[i]
        top = np.argpartition(-row, k)[:k] if k < n else np.arange(n)
        top = top[row[top] > 0]
        top = top[np.argsort(-row[top], kind="stable")]
        out_rows.append(np.full(len(top), i, dtype=np.int64))
        out_cols.append(top.astype(np.int64))
        out_weights.append(row[top].astype(np.float64))
    return (
        np.concatenate(out_rows) if out_rows else np.empty(0, dtype=np.int64),
        np.concatenate(out_cols) if out_cols else np.empty(0, dtype=np.int64),
        np.concatenate(out_weights) if out_weights else np.empty(0, dtype=np.float64),
    )


def to_sparse(rows: np.ndarray, cols: np.ndarray, weights: np.ndarray, n: int) -> sp.csr_matrix:
    return sp.csr_matrix((weights, (rows, cols)), shape=(n, n))
