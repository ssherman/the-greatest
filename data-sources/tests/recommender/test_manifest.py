from recommender.manifest import build, gate


def manifest(hit):
    return build(
        domain="books",
        export="2026-10-09",
        lam=500.0,
        min_readers=5,
        top_k=50,
        users=10,
        items=5,
        rows=20,
        eval_result={"seed": 1, "users": 8, "hit_at_10": hit, "recall_at_50": hit},
        previous=None,
    )


def test_build_carries_every_field_and_a_timestamp():
    m = manifest(0.3)
    assert m["domain"] == "books" and m["export"] == "2026-10-09"
    assert m["lambda"] == 500.0 and m["min_readers"] == 5 and m["top_k"] == 50
    assert m["users"] == 10 and m["items"] == 5 and m["rows"] == 20
    assert m["eval"]["hit_at_10"] == 0.3
    assert m["trained_at"].endswith("Z")
    assert m["previous"] is None


def test_gate_passes_without_a_previous_model_or_evaluation():
    assert gate(manifest(0.1), None, 0.9) == (True, "no previous model")
    ok, reason = gate(manifest(0.1), {"eval": {}}, 0.9)
    assert ok and "no evaluation" in reason


def test_gate_compares_hit_at_10_against_the_ratio():
    ok, _ = gate(manifest(0.27), manifest(0.30), 0.9)
    assert ok
    ok, reason = gate(manifest(0.26), manifest(0.30), 0.9)
    assert not ok
    assert "0.260" in reason and "0.300" in reason
