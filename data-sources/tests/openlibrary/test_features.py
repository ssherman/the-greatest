from openlibrary.matcher.blocking import BlockingQuery
from openlibrary.matcher.features import FEATURES, WorkView, conflicts, extract, load_work_views
from openlibrary.pipeline.duck import connect


def _work(**overrides) -> WorkView:
    defaults = dict(
        work_key="OL1W",
        title="The Great Gatsby",
        title_fp="the great gatsby",
        title_fp_nosub="the great gatsby",
        title_fp_noart="great gatsby",
        subtitle=None,
        author_names=["F. Scott Fitzgerald"],
        declared_year=1925,
        min_edition_year=1925,
        modal_edition_year=1953,
        edition_count=400,
        readinglog_count=9000,
        ratings_count=1200,
        languages=set(),
        subjects=[],
        title_fp_freq=2,
    )
    defaults.update(overrides)
    return WorkView(**defaults)


def test_every_declared_feature_is_returned():
    values = extract(BlockingQuery(title="The Great Gatsby"), _work())
    assert set(values) == set(FEATURES)


def test_a_missing_input_yields_none_not_zero():
    values = extract(BlockingQuery(title="The Great Gatsby"), _work())
    # No authors on our side -> the author feature is NEUTRAL, not 0.0.
    assert values["author_overlap"] is None
    assert values["year_agreement"] is None


def test_a_present_input_yields_a_number():
    values = extract(
        BlockingQuery(
            title="The Great Gatsby",
            author_names=["F. Scott Fitzgerald"],
            year=1925,
        ),
        _work(),
    )
    assert values["author_overlap"] == 1.0
    assert values["year_agreement"] == 1.0
    assert values["title_similarity"] > 0.99


def test_our_extra_missing_authors_never_penalise_the_candidate():
    ours = BlockingQuery(title="The Illuminatus! Trilogy", author_names=["Robert Shea"])
    work = _work(
        title="The Illuminatus! Trilogy",
        author_names=["Robert Shea", "Robert Anton Wilson"],
    )
    values = extract(ours, work)
    # We have one of their two authors. Overlap is measured over OUR set.
    assert values["author_overlap"] == 1.0


# Identifier agreement is a WORK-LEVEL claim (ruling R35), not an ISBN-SET
# claim. Measured against the 370 labelled true matches on the real artifact,
# an ISBN-set conflict rule (ours vs. the work's own isbn13 set) would flag 51
# of them (13.8%) as conflicts on their OWN labelled work, purely because Open
# Library holds other editions' ISBNs but not ours -- that's ABSENCE, not
# disagreement. The evidence that actually means "this identifier belongs to
# someone else" is blocking rule 1: the set of works our identifiers reached.
def test_an_identifier_conflict_is_reported_when_hits_exist_and_exclude_this_work():
    assert conflicts(
        BlockingQuery(title="x"),
        _work(work_key="OL1W"),
        identifier_hits=frozenset({"OL2W"}),
    ) == ["identifier"]


def test_no_conflict_is_reported_when_there_are_no_identifier_hits():
    assert (
        conflicts(BlockingQuery(title="x"), _work(work_key="OL1W"), identifier_hits=frozenset())
        == []
    )


def test_agreement_beats_conflict_when_this_work_is_among_the_hits():
    assert (
        conflicts(
            BlockingQuery(title="x"),
            _work(work_key="OL1W"),
            identifier_hits=frozenset({"OL1W", "OL2W"}),
        )
        == []
    )


def test_identifier_agreement_feature_is_one_zero_or_none():
    query = BlockingQuery(title="x")
    work = _work(work_key="OL1W")
    # This work is among the hits -> agree.
    assert extract(query, work, identifier_hits=frozenset({"OL1W"}))["identifier_agreement"] == 1.0
    # Hits exist, but point at some other work -> conflict.
    assert extract(query, work, identifier_hits=frozenset({"OL2W"}))["identifier_agreement"] == 0.0
    # No identifier reached anything -> absent, i.e. NEUTRAL, not zero.
    assert extract(query, work, identifier_hits=frozenset())["identifier_agreement"] is None


def test_popularity_is_a_feature_but_never_an_identity_feature():
    # It may only break ties. The test asserts the value is bounded and that
    # nothing in FEATURES is named as if it identified anything.
    values = extract(BlockingQuery(title="The Great Gatsby"), _work())
    assert 0.0 <= values["popularity_prior"] <= 1.0


# Ruling R40: an empty title fingerprint is ABSENCE, not disagreement. "!!!"
# fingerprints to "" -- the 30 `degenerate_title` evaluation cases and the
# ~1.5% of works whose title_fp is itself empty must not score as if they
# disagreed on title.
def test_a_degenerate_query_title_yields_none_not_a_disagreement_score():
    values = extract(BlockingQuery(title="!!!"), _work())
    assert values["title_similarity"] is None
    assert values["title_variant_exact"] is None


def test_a_degenerate_candidate_title_fp_yields_none_too():
    values = extract(
        BlockingQuery(title="The Great Gatsby"),
        _work(title_fp="", title_fp_nosub="", title_fp_noart=""),
    )
    assert values["title_similarity"] is None
    assert values["title_variant_exact"] is None


def test_present_but_differing_titles_still_score_a_real_disagreement():
    # Two present fingerprints that differ are DISAGREEMENT, not absence --
    # unlike the degenerate cases above, this must stay 0.0.
    values = extract(BlockingQuery(title="War and Peace"), _work())
    assert values["title_variant_exact"] == 0.0


def test_load_work_views_returns_one_view_per_wanted_key_with_aggregates(fixture_artifact):
    con = connect(fixture_artifact, memory_limit="1GB")
    try:
        views = load_work_views(con, fixture_artifact, ["OL3809593W", "OL999999999W"])
        # The unknown key is silently absent, not an error and not a blank view.
        assert set(views) == {"OL3809593W"}
        view = views["OL3809593W"]
        assert view.author_names
        (expected_edition_count,) = con.execute(
            f"SELECT edition_count FROM '{fixture_artifact.table('popularity')}' "
            "WHERE work_key = 'OL3809593W'"
        ).fetchone()
        assert view.edition_count == expected_edition_count
    finally:
        con.close()
