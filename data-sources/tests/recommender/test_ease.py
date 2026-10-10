import numpy as np
import scipy.sparse as sp

from recommender.ease import fit, to_sparse, top_neighbors

A, B, C, D, E = range(5)


def toy():
    # Six readers: A and B always together, C bridges, D and E on the other side.
    rows = [[A, B], [A, B], [A, B, C], [C, D], [C, D], [D, E]]
    X = sp.lil_matrix((len(rows), 5), dtype=np.float32)
    for u, items in enumerate(rows):
        for i in items:
            X[u, i] = 1.0
    return X.tocsr()


def test_fit_has_a_zero_diagonal_and_ranks_co_readership():
    W = fit(toy(), lam=1.0)
    assert W.shape == (5, 5)
    assert np.allclose(np.diag(W), 0.0)
    assert W[A, B] > W[A, C] > W[A, D], "B is read with A every time, C once, D never"
    assert W[D, C] > W[D, A]


def test_heavy_regularisation_shrinks_every_weight():
    W = fit(toy(), lam=1e6)
    assert np.abs(W).max() < 1e-3


def test_top_neighbors_keeps_k_positive_entries_per_row_in_descending_order():
    W = fit(toy(), lam=1.0)
    rows, cols, weights = top_neighbors(W, k=2)
    assert rows.dtype == np.int64 and cols.dtype == np.int64
    for i in range(5):
        mask = rows == i
        assert mask.sum() <= 2
        assert (weights[mask] > 0).all()
        assert (np.diff(weights[mask]) <= 0).all()
        assert i not in cols[mask]
    a = cols[rows == A]
    assert a[0] == B


def test_top_neighbors_with_k_larger_than_the_matrix():
    W = fit(toy(), lam=1.0)
    rows, cols, weights = top_neighbors(W, k=50)
    assert len(rows) == (W > 0).sum()


def test_to_sparse_round_trips():
    W = fit(toy(), lam=1.0)
    rows, cols, weights = top_neighbors(W, k=2)
    S = to_sparse(rows, cols, weights, n=5)
    assert S.shape == (5, 5)
    assert S.nnz == len(rows)
    assert np.isclose(S[A, B], W[A, B])
