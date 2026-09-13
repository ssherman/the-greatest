from openlibrary.matcher.decide import decide, rank
from openlibrary.matcher.scorer import ScoredCandidate, load_weights


def _c(work_key: str, score: float, conflicts=None, evidence=None) -> ScoredCandidate:
    if evidence is None:
        evidence = {"title_similarity": {"value": score, "weight": 1.0, "contribution": score}}
    return ScoredCandidate(
        work_key=work_key,
        score=score,
        rules=["title_fp"],
        evidence=evidence,
        conflicts=conflicts or [],
    )


def test_no_candidates_is_a_reject_not_a_crash():
    decision = decide([], load_weights())
    assert decision.verdict == "reject"
    assert decision.work_key is None


def test_a_clear_winner_is_accepted():
    weights = load_weights()
    decision = decide([_c("OL1W", 0.97), _c("OL2W", 0.40)], weights)
    assert decision.verdict == "accept"
    assert decision.work_key == "OL1W"
    assert decision.margin > weights.margin_threshold


def test_a_high_score_with_a_thin_margin_abstains():
    # THE failure this exists to prevent: five duplicate works, one picked at
    # 0.94 while another scores 0.93.
    decision = decide([_c("OL1W", 0.94), _c("OL2W", 0.93)], load_weights())
    assert decision.verdict == "abstain"
    assert "margin" in decision.reason


def test_everything_below_the_reject_threshold_is_rejected():
    decision = decide([_c("OL1W", 0.10), _c("OL2W", 0.05)], load_weights())
    assert decision.verdict == "reject"


def test_a_middling_score_abstains_rather_than_guessing():
    decision = decide([_c("OL1W", 0.65)], load_weights())
    assert decision.verdict == "abstain"


def test_a_conflict_on_the_best_candidate_can_never_be_accepted():
    decision = decide([_c("OL1W", 0.99, conflicts=["identifier"])], load_weights())
    assert decision.verdict == "abstain"
    assert "conflict" in decision.reason


def test_a_single_candidate_has_an_infinite_margin_in_effect():
    decision = decide([_c("OL1W", 0.97)], load_weights())
    assert decision.verdict == "accept"
    assert decision.margin is not None


def test_rank_orders_by_score_descending_and_is_stable_on_ties():
    ordered = rank([_c("OL2W", 0.5), _c("OL1W", 0.5), _c("OL3W", 0.9)])
    assert [c.work_key for c in ordered] == ["OL3W", "OL1W", "OL2W"]


def test_popularity_alone_can_never_be_accepted():
    evidence = {
        "popularity_prior": {
            "value": 1.0,
            "weight": 0.1,
            "contribution": 0.1,
        },
        "title_similarity": {
            "value": None,
            "weight": 1.0,
            "contribution": 0.0,
        },
    }
    decision = decide(
        [_c("OL1W", 1.0, evidence=evidence)],
        load_weights(),
    )
    assert decision.verdict == "abstain"
    assert "identity" in decision.reason


def test_an_identity_feature_alongside_the_prior_is_enough():
    evidence = {
        "popularity_prior": {
            "value": 1.0,
            "weight": 0.1,
            "contribution": 0.1,
        },
        "author_overlap": {
            "value": 1.0,
            "weight": 1.0,
            "contribution": 1.0,
        },
        "title_similarity": {
            "value": None,
            "weight": 1.0,
            "contribution": 0.0,
        },
    }
    decision = decide(
        [_c("OL1W", 1.0, evidence=evidence)],
        load_weights(),
    )
    assert decision.verdict == "accept"
