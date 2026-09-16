from common.schemas import (
    DiffEntry,
    Envelope,
    RedirectInfo,
    SourceKey,
    SourceVersion,
    classify_diff,
)


def test_a_key_always_names_its_source():
    key = SourceKey(source="openlibrary", key="OL81205W")
    assert key.model_dump() == {"source": "openlibrary", "key": "OL81205W"}


def test_an_envelope_always_carries_the_source_version():
    version = SourceVersion(
        source="openlibrary",
        dump_date="2026-07-31",
        normalizer_version=1,
        pipeline_version=1,
        matcher_version=1,
    )
    envelope = Envelope[dict](source_version=version, data={"a": 1})
    assert envelope.source_version.dump_date == "2026-07-31"


def test_redirect_information_lists_where_a_key_came_from():
    info = RedirectInfo(redirected_from=[SourceKey(source="openlibrary", key="OL1W")])
    assert info.redirected_from[0].key == "OL1W"


def test_an_empty_local_value_is_a_fill():
    # Given editions, credits, series and relationships are empty, most results
    # are fills. A fill is safe to apply in bulk; a conflict needs judgement.
    assert classify_diff(None, 1925) == "fill"
    assert classify_diff("", "Gatsby") == "fill"
    assert classify_diff([], ["Fitzgerald"]) == "fill"


def test_matching_values_are_agreement_not_a_change():
    assert classify_diff(1925, 1925) == "agreement"


def test_differing_populated_values_are_a_conflict():
    assert classify_diff(1925, 1953) == "conflict"


def test_extra_structure_on_their_side_is_an_enrichment():
    assert classify_diff(["Shea"], ["Shea", "Wilson"]) == "enrichment"


def test_a_missing_remote_value_is_absent_not_agreement():
    assert classify_diff(1925, None) == "absent"
    assert classify_diff(None, None) == "absent"


def test_diff_entry_carries_both_sides():
    entry = DiffEntry(field="first_published_year", ours=None, theirs=1925, kind="fill")
    assert entry.kind == "fill"
