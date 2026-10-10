import numpy as np
import scipy.sparse as sp

from recommender.evaluate import hold_one_out, metrics


def matrix(rows):
    X = sp.lil_matrix((len(rows), 6), dtype=np.float32)
    for u, items in enumerate(rows):
        for i in items:
            X[u, i] = 1.0
    return X.tocsr()


def test_hold_one_out_hides_one_positive_per_eligible_user_deterministically():
    X = matrix([[0, 1, 2], [0, 1, 2, 3], [4], [0, 1, 2, 3, 4]])
    a = hold_one_out(X, seed=3, min_positives=3)
    b = hold_one_out(X, seed=3, min_positives=3)
    assert a.users.tolist() == [0, 1, 3]
    assert a.held.tolist() == b.held.tolist()
    for u, h in zip(a.users, a.held, strict=True):
        assert X[u, h] == 1.0
        assert a.train[u, h] == 0.0
        assert a.train[u].sum() == X[u].sum() - 1
    assert a.train[2].sum() == 1.0, "ineligible users keep everything"


def test_metrics_count_a_held_item_in_the_top_k_and_never_recommend_seen_items():
    train = matrix([[0, 1], [2, 3]])
    # item 0 leads to 4 strongly, 1 leads to 5; item 2 leads to 1, and 3 leads to 0
    model = sp.csr_matrix(
        (np.array([0.9, 0.5, 0.7, 0.2]), (np.array([0, 1, 2, 3]), np.array([4, 5, 1, 0]))),
        shape=(6, 6),
    )
    users = np.array([0, 1])
    held = np.array([4, 1])
    out = metrics(train, model, users, held, k_hit=1, k_recall=2)
    assert out["users"] == 2
    assert out["hit_at_10"] == 1.0, "user 0's top-1 is item 4; user 1's top-1 is item 1"
    assert out["recall_at_50"] == 1.0
    # user 0 scores {4: 0.9, 5: 0.5}: held 5 is rank 2 (recall only, no hit@1).
    # user 1 scores {1: 0.7, 0: 0.2}: held 1 is rank 1 (hit). The brief held 0 for
    # user 1, which is rank 2, giving hit 0.0 not 0.5; held [5, 1] restores the intent.
    out = metrics(train, model, users, np.array([5, 1]), k_hit=1, k_recall=2)
    assert out["hit_at_10"] == 0.5
    assert out["recall_at_50"] == 1.0


def test_metrics_mask_seen_items():
    train = matrix([[0, 1]])
    model = sp.csr_matrix(
        (np.array([5.0, 0.1]), (np.array([0, 1]), np.array([1, 2]))), shape=(6, 6)
    )
    out = metrics(train, model, np.array([0]), np.array([2]), k_hit=1, k_recall=1)
    assert out["hit_at_10"] == 1.0, "item 1 scores highest but is already on the shelf"


def test_metrics_with_no_users():
    out = metrics(
        matrix([[0]]),
        sp.csr_matrix((6, 6)),
        np.array([], dtype=np.int64),
        np.array([], dtype=np.int64),
    )
    assert out == {"users": 0, "hit_at_10": 0.0, "recall_at_50": 0.0}
