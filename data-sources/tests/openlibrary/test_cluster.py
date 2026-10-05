from openlibrary.matcher.cluster import ClusterInputs, build_clusters, cluster_inputs
from openlibrary.matcher.features import FEATURES, WorkView
from openlibrary.matcher.scorer import MATCHER_VERSION, ScoredCandidate, Weights


def _weights(ratio=3.0):
    return Weights(
        matcher_version=MATCHER_VERSION,
        calibrated=False,
        feature_weights=dict.fromkeys(FEATURES, 1.0),
        conflict_penalties={"identifier": 0.35},
        accept_threshold=0.9,
        reject_threshold=0.4,
        margin_threshold=0.05,
        duplicate_dominance_ratio=ratio,
    )


def _c(key, score, *, year=None, identifier=None):
    evidence = {
        "title_similarity": {"value": 1.0, "weight": 1.0, "contribution": 1.0},
        "year_agreement": {"value": year, "weight": 1.0, "contribution": 0.0},
        "identifier_agreement": {"value": identifier, "weight": 1.0, "contribution": 0.0},
    }
    return ScoredCandidate(work_key=key, score=score, rules=["author_title"], evidence=evidence)


def _in(fp="dune", noart=None, raw=None, author="frank herbert", editions=1):
    return ClusterInputs(
        title_fp=fp,
        title_fp_noart=fp if noart is None else noart,
        title_raw=fp if raw is None else raw,
        author_fps=[author],
        edition_count=editions,
    )


def _pair(a, b):
    return build_clusters([_c("OLA", 0.95), _c("OLB", 0.95)], {"OLA": a, "OLB": b}, _weights())


def test_cluster_inputs_come_from_the_work_view_and_never_the_subtitle_stripped_fingerprint():
    work = WorkView(
        work_key="OLA",
        title="The Dune: Part One",
        title_fp="the dune part one",
        title_fp_nosub="the dune",
        title_fp_noart="dune part one",
        author_names=["Frank Herbert", "Herbert, Frank"],
        edition_count=7,
    )
    inputs = cluster_inputs(work)
    assert inputs.title_fp == "the dune part one"
    assert inputs.title_fp_noart == "dune part one"
    assert inputs.title_raw == "The Dune: Part One"
    assert inputs.edition_count == 7
    assert inputs.author_fps
    assert 'the dune"' not in inputs.model_dump_json()


def test_same_title_and_author_form_one_cluster_with_the_dominant_representative():
    idx = build_clusters(
        [_c("OLA", 0.96), _c("OLB", 0.95), _c("OLC", 0.94)],
        {"OLA": _in(editions=3), "OLB": _in(editions=160), "OLC": _in(editions=1)},
        _weights(),
    )
    cid = idx.of["OLA"]
    assert idx.of["OLB"] == cid == idx.of["OLC"]
    assert idx.representative[cid] == "OLB"
    assert idx.best_score[cid] == 0.96


def test_no_dominant_member_means_no_representative():  # Dickinson's 16 "Poems"
    idx = build_clusters(
        [_c("OLA", 0.95), _c("OLB", 0.95), _c("OLC", 0.95)],
        {
            "OLA": _in("poems", editions=14),
            "OLB": _in("poems", editions=10),
            "OLC": _in("poems", editions=10),
        },
        _weights(),
    )
    assert idx.representative[idx.of["OLA"]] is None


def test_tied_edition_counts_have_no_representative():  # Review Focus 2
    idx = build_clusters(
        [_c("OLA", 0.95), _c("OLB", 0.95)],
        {"OLA": _in(editions=5), "OLB": _in(editions=5)},
        _weights(ratio=1.5),
    )
    assert idx.representative[idx.of["OLA"]] is None


def test_zero_edition_counts_have_no_representative():  # Review Focus 2
    idx = build_clusters(
        [_c("OLA", 0.95), _c("OLB", 0.95)],
        {"OLA": _in(editions=0), "OLB": _in(editions=0)},
        _weights(),
    )
    assert idx.representative[idx.of["OLA"]] is None


def test_the_identifier_agreeing_member_represents_the_cluster():
    idx = build_clusters(
        [_c("OLA", 0.95, identifier=1.0), _c("OLB", 0.95)],
        {"OLA": _in(editions=1), "OLB": _in(editions=500)},
        _weights(),
    )
    assert idx.representative[idx.of["OLA"]] == "OLA"


def test_different_authors_never_cluster():
    idx = _pair(_in(author="a"), _in(author="b"))
    assert idx.of["OLA"] != idx.of["OLB"]


def test_diverging_year_agreement_keeps_same_titled_works_apart():
    idx = build_clusters(
        [_c("OLA", 0.95, year=1.0), _c("OLB", 0.9, year=0.3)],
        {"OLA": _in(), "OLB": _in()},
        _weights(),
    )
    assert idx.of["OLA"] != idx.of["OLB"]


def test_one_missing_year_does_not_block_clustering():
    idx = build_clusters(
        [_c("OLA", 0.95, year=1.0), _c("OLB", 0.9, year=None)],
        {"OLA": _in(editions=50), "OLB": _in(editions=1)},
        _weights(),
    )
    assert idx.of["OLA"] == idx.of["OLB"]


def test_titleless_candidates_and_candidates_without_inputs_are_singletons():
    titleless = ScoredCandidate(work_key="OLT", score=0.913, rules=["author_shelf"], evidence={})
    idx = build_clusters(
        [_c("OLA", 0.95), titleless, _c("OLN", 0.9)],
        {"OLA": _in(), "OLT": _in()},
        _weights(),
    )
    assert idx.members[idx.of["OLT"]] == ["OLT"]
    assert idx.members[idx.of["OLN"]] == ["OLN"]


def test_a_shared_subtitle_stripped_title_alone_does_not_cluster():  # Ruling 7
    omnibus = _in("the lord of the rings", noart="lord of the rings", editions=900)
    towers = _in(
        "the lord of the rings the two towers",
        noart="lord of the rings the two towers",
        editions=5,
    )
    idx = _pair(omnibus, towers)
    assert idx.of["OLA"] != idx.of["OLB"]


def test_a_cross_match_of_full_against_article_stripped_does_not_cluster():  # Ruling 7
    idx = _pair(_in("dune messiah", noart="messiah"), _in("the messiah", noart="dune messiah"))
    assert idx.of["OLA"] != idx.of["OLB"]


def test_an_article_stripped_match_clusters():  # Ruling 7
    idx = _pair(_in("the dune", noart="dune", editions=100), _in("dune", noart="dune"))
    assert idx.of["OLA"] == idx.of["OLB"]


def test_a_short_fingerprint_with_different_raw_titles_does_not_cluster():  # Ruling 9
    idx = _pair(_in("6", raw="エマ 6"), _in("6", raw="シャーリー 6"))
    assert idx.of["OLA"] != idx.of["OLB"]


def test_a_short_fingerprint_with_equal_raw_titles_clusters():  # Ruling 9
    idx = _pair(_in("q a", raw="Q&a", editions=20), _in("q a", raw="Q & A"))
    assert idx.of["OLA"] == idx.of["OLB"]


def test_empty_fingerprints_never_cluster():
    idx = _pair(_in("", noart="", raw=""), _in("", noart="", raw=""))
    assert idx.of["OLA"] != idx.of["OLB"]
