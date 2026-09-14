from openlibrary.matcher.decide import decide, rank
from openlibrary.matcher.features import FEATURES
from openlibrary.matcher.scorer import MATCHER_VERSION, ScoredCandidate, Weights


def _equal_weights() -> Weights:
    """An equal-weights `Weights`, built inline -- NOT `load_weights()`.

    `weights.json` is the real, calibrated shipped file (Task 27); every
    test below asserts a specific accept/reject/abstain boundary against a
    literal score, so it needs the FIXED thresholds those literals were
    written against (0.9 / 0.4 / 0.05), not whatever the latest calibration
    run happened to produce. `decide()` never reads `feature_weights` --
    only the three thresholds -- so their values here don't matter, but a
    valid `Weights` still needs exactly the declared `FEATURES` keys. This
    module must not import `openlibrary.eval`, so it is not shared with
    `test_scorer.py`'s `_weights_payload`.
    """
    return Weights(
        matcher_version=MATCHER_VERSION,
        calibrated=False,
        calibrated_at=None,
        feature_weights=dict.fromkeys(FEATURES, 1.0),
        conflict_penalties={"identifier": 0.35},
        accept_threshold=0.9,
        reject_threshold=0.4,
        margin_threshold=0.05,
    )


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
    decision = decide([], _equal_weights())
    assert decision.verdict == "reject"
    assert decision.work_key is None


def test_no_candidates_with_a_tripped_volume_guard_abstains_instead(  # R59
):
    """Blocking found something and refused to fetch it (a 1,226-work author
    shelf, an identifier on 200+ works). That is not "not in Open Library";
    recording it as a reject was the v1 false reject (degenerate_title-014)."""
    decision = decide([], _equal_weights(), volume_guards_tripped=["author_shelf"])
    assert decision.verdict == "abstain"
    assert decision.work_key is None
    assert decision.reason == "no candidates; search refused for volume: author_shelf"


def test_weak_candidates_with_a_tripped_volume_guard_abstain_instead_of_rejecting():
    """R59, extended: the labelled false reject that survived the zero-candidate
    rule was no_candidates-030 ("Donne Innamorate", D.H. Lawrence) -- shelf
    refused for volume, then rule 6 filled 200 fuzzy fallbacks none of which
    is the book, best 0.397 < 0.4. "Below the reject threshold" is only "not
    in Open Library" when the search was allowed to look; here it was not."""
    decision = decide(
        [_c("OL1W", 0.39), _c("OL2W", 0.38)],
        _equal_weights(),
        volume_guards_tripped=["author_shelf"],
    )
    assert decision.verdict == "abstain"
    assert decision.work_key == "OL1W"
    assert decision.reason == (
        "best score 0.390 below reject threshold 0.400; search refused for volume: author_shelf"
    )


def test_a_volume_guard_does_not_touch_the_accept_or_middle_bands():
    """The extension only converts the reject band. A clear winner still
    accepts and a middling score still abstains for its own reason."""
    weights = _equal_weights()
    accepted = decide([_c("OL1W", 0.97)], weights, volume_guards_tripped=["author_shelf"])
    assert accepted.verdict == "accept"
    middling = decide([_c("OL1W", 0.65)], weights, volume_guards_tripped=["author_shelf"])
    assert middling.verdict == "abstain"
    assert "between reject and accept" in middling.reason


def test_no_candidates_and_no_volume_guard_is_still_a_reject():
    """The control for the test above: an empty `volume_guards_tripped` --
    including the case where only the empty/short-fingerprint `title_fp`
    guard fired, which is not a volume guard -- keeps the reject."""
    decision = decide([], _equal_weights(), volume_guards_tripped=[])
    assert decision.verdict == "reject"
    assert decision.reason == "no candidates"


def test_a_clear_winner_is_accepted():
    weights = _equal_weights()
    decision = decide([_c("OL1W", 0.97), _c("OL2W", 0.40)], weights)
    assert decision.verdict == "accept"
    assert decision.work_key == "OL1W"
    assert decision.margin > weights.margin_threshold


def test_a_high_score_with_a_thin_margin_abstains():
    # THE failure this exists to prevent: five duplicate works, one picked at
    # 0.94 while another scores 0.93.
    decision = decide([_c("OL1W", 0.94), _c("OL2W", 0.93)], _equal_weights())
    assert decision.verdict == "abstain"
    assert "margin" in decision.reason


def test_everything_below_the_reject_threshold_is_rejected():
    decision = decide([_c("OL1W", 0.10), _c("OL2W", 0.05)], _equal_weights())
    assert decision.verdict == "reject"


def test_a_middling_score_abstains_rather_than_guessing():
    decision = decide([_c("OL1W", 0.65)], _equal_weights())
    assert decision.verdict == "abstain"


def test_a_conflict_on_the_best_candidate_can_never_be_accepted():
    decision = decide([_c("OL1W", 0.99, conflicts=["identifier"])], _equal_weights())
    assert decision.verdict == "abstain"
    assert "conflict" in decision.reason


def test_a_single_candidate_has_an_infinite_margin_in_effect():
    decision = decide([_c("OL1W", 0.97)], _equal_weights())
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
        _equal_weights(),
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
        "title_similarity": {
            "value": 1.0,
            "weight": 1.0,
            "contribution": 1.0,
        },
        "author_overlap": {
            "value": None,
            "weight": 1.0,
            "contribution": 0.0,
        },
    }
    decision = decide(
        [_c("OL1W", 1.0, evidence=evidence)],
        _equal_weights(),
    )
    assert decision.verdict == "accept"


def _present(**values: float) -> dict:
    """Evidence with the named features present and every other feature
    absent, as `score_features` writes it."""
    evidence = {name: {"value": None, "weight": 1.0, "contribution": 0.0} for name in FEATURES}
    for name, value in values.items():
        evidence[name] = {"value": value, "weight": 1.0, "contribution": value}
    return evidence


# Ruling R58: author agreement identifies the author, not the book. The two
# measured false merges this closes (degenerate_title-013, pseudonym_or_alt_
# name-001) both scored 0.91-0.95 on author_overlap + author_name_similarity
# with no title feature present -- a Bengali/Cyrillic title against a Latin
# fingerprint yields None for every title feature (R40), so the weighted mean
# WAS the author agreement.
def test_author_agreement_alone_can_never_be_accepted():
    evidence = _present(author_overlap=1.0, author_name_similarity=1.0, popularity_prior=0.5)
    decision = decide([_c("OL1W", 1.0, evidence=evidence)], _equal_weights())
    assert decision.verdict == "abstain"
    assert decision.reason == (
        "no identity evidence: only author/year/language/popularity are present"
    )


def test_year_and_language_alongside_author_still_do_not_make_identity():
    evidence = _present(
        author_overlap=1.0, author_name_similarity=1.0, year_agreement=1.0, language_agreement=1.0
    )
    decision = decide([_c("OL1W", 1.0, evidence=evidence)], _equal_weights())
    assert decision.verdict == "abstain"
    assert "identity" in decision.reason


def test_author_agreement_with_a_present_title_feature_is_accepted():
    evidence = _present(author_overlap=1.0, author_name_similarity=1.0, title_similarity=0.96)
    decision = decide([_c("OL1W", 0.98, evidence=evidence)], _equal_weights())
    assert decision.verdict == "accept"


def test_author_agreement_with_an_agreeing_identifier_is_accepted():
    evidence = _present(author_overlap=1.0, author_name_similarity=1.0, identifier_agreement=1.0)
    decision = decide([_c("OL1W", 1.0, evidence=evidence)], _equal_weights())
    assert decision.verdict == "accept"


def test_a_disagreeing_identifier_is_not_identity_evidence():
    """identifier_agreement == 0.0 is a conflict, not a comparison of the
    book itself; only 1.0 counts. (In practice a 0.0 also arrives with a
    `conflicts` entry and abstains one check earlier -- this pins the guard
    on its own.)"""
    evidence = _present(author_overlap=1.0, author_name_similarity=1.0, identifier_agreement=0.0)
    decision = decide([_c("OL1W", 0.95, evidence=evidence)], _equal_weights())
    assert decision.verdict == "abstain"
    assert "identity" in decision.reason
