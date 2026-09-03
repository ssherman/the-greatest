"""`assign_strata`'s own tests.

Before these existed the function had none, and the `non_latin_title` bug --
a threshold that put Greek and Cyrillic *below* the cut and typographic
punctuation above it -- shipped into a 450-case labelling pool because nothing
could catch it. A stratum predicate that never fires looks exactly like a
predicate that fires correctly on data which happens not to contain its class.

Each test states the ONE field it varies away from `ordinary_book`, which trips
no predicate at all and lands in `no_candidates`. Precedence is part of the
contract -- a book satisfying several predicates belongs to the most specific
one -- so the order is tested directly rather than assumed.
"""

from __future__ import annotations

import pytest

from openlibrary.eval.build_pool import assign_strata, naive_candidates
from openlibrary.eval.schema import STRATA, EvalBook
from openlibrary.pipeline.duck import connect

# Real keys and names from the committed fixture corpus. Each property they are
# picked for is pinned by tests/fixtures/test_fixture_corpus.py, so a corpus
# regeneration that loses one fails there rather than silently here.
AUTHORLESS_WORK = "OL13746649W"  # "English Fiddle Tunes" -- author_count = 0
POPULAR_WORK = "OL3809593W"  # "The Illuminatus! Trilogy" -- 79 reading-log, 15 ratings
ANOTHER_POPULAR_WORK = "OL10530571W"  # "Fire and Ice" -- 53 reading-log, 4 ratings
UNPOPULAR_WORK = "OL11729038W"  # "British ships and British seamen" -- 1 author, 0 signal
ALTERNATE_ONLY_NAME = "Frederick Beigbeder"  # OL3113863A carries it as an alternate only
PRIMARY_AND_ALTERNATE_NAME = "D. H. Lawrence"  # OL19964A: 1 primary spelling + 16 alternates
NO_SUCH_WORK = "OL999999999W"  # absent from works.parquet: a stale stored key
CROWDED_TITLE_WORK = "OL999999101W"  # one of 51 corpus works titled "Selected Poems"


def strata_of(paths, books: list[EvalBook]) -> dict[int, str]:
    """book_id -> the single stratum it was claimed by (absent when unclaimed)."""
    con = connect(paths, memory_limit="1GB")
    candidates = naive_candidates(con, paths, books)
    assigned = assign_strata(con, paths, books, candidates)
    con.close()
    claimed: dict[int, str] = {}
    for stratum, book_ids in assigned.items():
        for book_id in book_ids:
            assert book_id not in claimed, f"book {book_id} claimed twice"
            claimed[book_id] = stratum
    return claimed


@pytest.fixture()
def ordinary_book():
    """A book that trips no predicate, to be varied one field at a time."""

    def make(book_id: int = 1, **overrides) -> EvalBook:
        fields = {
            "book_id": book_id,
            "title": "A Perfectly Ordinary Title Nobody Else Has",
            "author_names": ["Ordinary Author"],
        }
        fields.update(overrides)
        return EvalBook(**fields)

    return make


def test_the_control_book_trips_nothing_and_falls_through_to_no_candidates(
    fixture_artifact, ordinary_book
):
    """Pins the baseline every other test varies from. If this ever moves, the
    other tests are no longer isolating the field they claim to isolate."""
    assert strata_of(fixture_artifact, [ordinary_book()])[1] == "no_candidates"


def test_a_key_stored_on_more_than_one_book_is_a_shared_key_collision(
    fixture_artifact, ordinary_book
):
    books = [
        ordinary_book(1, existing_ol_work_keys=[POPULAR_WORK]),
        ordinary_book(2, title="A Different Ordinary Title", existing_ol_work_keys=[POPULAR_WORK]),
    ]

    claimed = strata_of(fixture_artifact, books)

    assert claimed[1] == "shared_key_collision"
    assert claimed[2] == "shared_key_collision"


def test_a_stored_key_that_no_longer_exists_is_a_stale_ol_key(fixture_artifact, ordinary_book):
    subject = ordinary_book(existing_ol_work_keys=[NO_SUCH_WORK])

    assert strata_of(fixture_artifact, [subject])[1] == "stale_ol_key"


def test_a_shared_key_outranks_a_stale_one(fixture_artifact, ordinary_book):
    """Both predicates hold; `shared_key_collision` is claimed first because a
    key on several books is the more specific problem."""
    books = [
        ordinary_book(1, existing_ol_work_keys=[NO_SUCH_WORK]),
        ordinary_book(2, title="A Different Ordinary Title", existing_ol_work_keys=[NO_SUCH_WORK]),
    ]

    claimed = strata_of(fixture_artifact, books)

    assert claimed[1] == "shared_key_collision"
    assert claimed[2] == "shared_key_collision"


def test_a_title_that_fingerprints_to_nothing_is_a_degenerate_title(
    fixture_artifact, ordinary_book
):
    subject = ordinary_book(title="!!!")

    assert strata_of(fixture_artifact, [subject])[1] == "degenerate_title"


def test_a_title_carrying_a_non_latin_letter_is_a_non_latin_title(fixture_artifact, ordinary_book):
    """Cyrillic sits at U+0400, Greek at U+0370 -- both BELOW the U+2000 the
    predicate originally used, so the scripts the stratum exists for were
    structurally unreachable while en dashes claimed pure-Latin titles.

    The title has to keep four Latin characters: `fingerprint` erases non-Latin
    script entirely, so a title in Cyrillic ALONE fingerprints to the empty
    string and `degenerate_title` -- claimed earlier -- takes it first. That is
    not a hypothetical: all 30 non_latin_title cases in the 450-case pool are
    mixed-script, every one with a Latin fingerprint of 4 characters or more.
    """
    subject = ordinary_book(title="Dracula / Дракула")

    assert strata_of(fixture_artifact, [subject])[1] == "non_latin_title"


def test_typographic_punctuation_alone_is_not_a_non_latin_title(fixture_artifact, ordinary_book):
    """An en dash is U+2013 -- above U+2000, and not a letter. Under the
    predicate this branch shipped with, this pure-Latin title was claimed as
    non-Latin, and 8 of the 30 cases in the pool as first drawn were titles
    like it. The pool has since been redrawn against the corrected predicate."""
    subject = ordinary_book(title="Novels 1896–1899")

    assert strata_of(fixture_artifact, [subject])[1] != "non_latin_title"


def test_a_book_whose_only_candidate_has_no_author_is_author_less_work(
    fixture_artifact, ordinary_book
):
    """The stratum is 'our book has no author, OR the OL candidate has none'.

    Testing only the local half leaves the candidate half unexercised, and the
    candidate half is the one the matcher has to reason about: a local book
    WITH authors against an OL work that has none, where author agreement can
    say nothing either way.
    """
    subject = ordinary_book(title="English Fiddle Tunes", existing_ol_work_keys=[AUTHORLESS_WORK])

    assert strata_of(fixture_artifact, [subject])[1] == "author_less_work"


def test_a_book_with_no_author_of_its_own_is_still_author_less_work(
    fixture_artifact, ordinary_book
):
    subject = ordinary_book(author_names=[], existing_ol_work_keys=[POPULAR_WORK])

    assert strata_of(fixture_artifact, [subject])[1] == "author_less_work"


def test_an_author_reachable_only_through_an_alternate_name_is_a_pseudonym(
    fixture_artifact, ordinary_book
):
    subject = ordinary_book(author_names=[ALTERNATE_ONLY_NAME])

    assert strata_of(fixture_artifact, [subject])[1] == "pseudonym_or_alt_name"


def test_an_author_matching_a_primary_name_is_not_a_pseudonym(fixture_artifact, ordinary_book):
    """The stratum is 'reachable ONLY through an alternate name'. Without this
    control the predicate could be 'matches any author name at all' and every
    test above would still pass."""
    subject = ordinary_book(author_names=["Amelia Atwater-Rhodes"])

    assert strata_of(fixture_artifact, [subject])[1] != "pseudonym_or_alt_name"


def test_an_author_matching_a_primary_AND_an_alternate_name_is_not_a_pseudonym(
    fixture_artifact, ordinary_book
):
    """The word doing the work in the stratum is ONLY.

    `D. H. Lawrence` fingerprints to a name OL19964A carries once as its
    primary and sixteen more times as alternate spellings -- so both halves of
    the HAVING are non-zero and the book must not be claimed. Without this,
    loosening `count(*) FILTER (WHERE source = 'primary') = 0` to `>= 0`, or
    dropping that clause outright, passes every other test here: the
    alternate-only control has no primary match to be forgiven, and the
    primary-only control has no alternate to satisfy the other half.
    """
    subject = ordinary_book(author_names=[PRIMARY_AND_ALTERNATE_NAME])

    assert strata_of(fixture_artifact, [subject])[1] != "pseudonym_or_alt_name"


def test_a_collection_word_in_the_title_is_an_anthology(fixture_artifact, ordinary_book):
    subject = ordinary_book(title="The Collected Stories Of Nobody At All")

    assert strata_of(fixture_artifact, [subject])[1] == "anthology_or_collection"


def test_candidates_with_no_reading_log_and_no_ratings_are_no_popularity_signal(
    fixture_artifact, ordinary_book
):
    subject = ordinary_book(existing_ol_work_keys=[UNPOPULAR_WORK])

    assert strata_of(fixture_artifact, [subject])[1] == "no_popularity_signal"


def test_one_candidate_with_a_signal_is_enough_to_leave_no_popularity_signal(
    fixture_artifact, ordinary_book
):
    """`all(...)`, not `any(...)`: the stratum is for books popularity CANNOT
    decide, so a single candidate carrying a signal disqualifies the book.

    Two candidates also put it past `easy_baseline`'s "exactly one", so this is
    the one shape that pins both thresholds -- with a single candidate, `all`
    and `any` agree and `== 1` and `>= 0` agree, and every other test here
    passes under either. It ends up in no stratum at all, which is correct: a
    mixed-signal book is not one of the twelve hard cases the pool samples.
    """
    subject = ordinary_book(existing_ol_work_keys=[POPULAR_WORK, UNPOPULAR_WORK])

    claimed = strata_of(fixture_artifact, [subject])

    assert claimed.get(1) is None, f"expected no stratum, got {claimed.get(1)}"


def test_exactly_one_candidate_with_a_popularity_signal_is_the_easy_baseline(
    fixture_artifact, ordinary_book
):
    subject = ordinary_book(existing_ol_work_keys=[POPULAR_WORK])

    assert strata_of(fixture_artifact, [subject])[1] == "easy_baseline"


def test_an_isbn_pointing_at_two_works_is_isbn_reuse(fixture_artifact, ordinary_book):
    """9780028972459 is on editions of both OL108593W and OL269642W. Until the
    corpus carried it, `_reused_isbns` returned the empty set on every input
    and this stratum was unreachable."""
    subject = ordinary_book(isbn13=["9780028972459"])

    assert strata_of(fixture_artifact, [subject])[1] == "isbn_reuse"


def test_a_candidate_sharing_its_title_with_fifty_others_is_high_frequency(
    fixture_artifact, ordinary_book
):
    """The candidate arrives through the stored-key rule, not the title rule --
    rule 4 refuses to return anything this crowded, which is the point. The
    stratum exists so the labeller sees the case anyway."""
    subject = ordinary_book(existing_ol_work_keys=[CROWDED_TITLE_WORK])

    assert strata_of(fixture_artifact, [subject])[1] == "high_frequency_title"


def test_every_book_is_claimed_by_at_most_one_stratum(fixture_artifact, ordinary_book):
    """The whole set at once, which is how the pool builder calls it. `strata_of`
    raises if any book appears twice."""
    books = [
        ordinary_book(1),
        ordinary_book(2, title="!!!"),
        ordinary_book(3, title="Dracula / Дракула"),
        ordinary_book(4, existing_ol_work_keys=[NO_SUCH_WORK]),
        ordinary_book(5, existing_ol_work_keys=[AUTHORLESS_WORK]),
        ordinary_book(6, author_names=[ALTERNATE_ONLY_NAME]),
        ordinary_book(7, title="The Collected Stories Of Nobody At All"),
        ordinary_book(8, existing_ol_work_keys=[UNPOPULAR_WORK]),
        ordinary_book(9, existing_ol_work_keys=[ANOTHER_POPULAR_WORK]),
    ]

    claimed = strata_of(fixture_artifact, books)

    assert claimed == {
        1: "no_candidates",
        2: "degenerate_title",
        3: "non_latin_title",
        4: "stale_ol_key",
        5: "author_less_work",
        6: "pseudonym_or_alt_name",
        7: "anthology_or_collection",
        8: "no_popularity_signal",
        9: "easy_baseline",
    }
    assert set(claimed.values()) <= set(STRATA)
