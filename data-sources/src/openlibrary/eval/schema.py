"""The labeled-case shape.

This set is the only ground truth that exists for the matcher. The 31,602 stored
OL work keys are untrusted: 9.9% are dead and 380 are attached to more than one
book, for four different reasons. They seed cases; they never settle them.

Stratified, not sampled: a random sample of 126,330 books is about 90% easy
cases and would report a matcher as excellent while it destroys data on the
other 10%.
"""

from __future__ import annotations

import datetime
from typing import Literal

from pydantic import BaseModel, Field, model_validator

MIN_CASES = 300
MAX_CASES = 500
MIN_NO_MATCH_CASES = 20

# stratum -> minimum number of labeled cases. Sums to 450.
STRATA: dict[str, int] = {
    # The 380 work keys attached to more than one of our books. Already contains
    # real duplicates, translations, omnibus confusion and wrong data.
    "shared_key_collision": 80,
    # The 3,064 stored keys that no longer exist in the dump.
    "stale_ol_key": 30,
    # The control group: books with exactly one union candidate (44.6% of the
    # catalog). Without these the metrics have no baseline.
    "easy_baseline": 60,
    # title_fp_freq > 50: "selected poems", "collected works".
    "high_frequency_title": 40,
    # Cyrillic, CJK, Greek. The fingerprint erases these; see the plan's
    # measured-facts section.
    "non_latin_title": 30,
    # The 3,360 books whose title fingerprint is shorter than 4 characters.
    "degenerate_title": 20,
    # 27.9% of the works our books link to have zero reading-log and zero
    # ratings. Popularity must not be able to decide these.
    "no_popularity_signal": 30,
    # Author reachable only through author_names.source = 'alternate'.
    "pseudonym_or_alt_name": 30,
    "anthology_or_collection": 30,
    # Our book has no author, or the OL candidate has none.
    "author_less_work": 20,
    # One ISBN pointing at more than one work.
    "isbn_reuse": 30,
    # Naive blocking produced nothing. The label decides whether that is a true
    # negative or a recall failure -- both outcomes are valuable.
    "no_candidates": 50,
}

# From the design's identity table. These are matcher OUTPUTS: the local schema
# encodes them but has never exercised them (book_kind is 100% standalone,
# book_relationships is empty, there are 19 credits in total).
IDENTITY_RULES = (
    "same_work",
    "translation",  # Books::Edition with language_id; same Book
    "revised_edition",  # edition_type: revised; same Book
    "omnibus_vs_parts",  # BookRelationship#contains; different Books, linked
    "collection",  # book_kind: collection; its own Book
    "adaptation",  # relation_type: adaptation_of; different Book
    "duplicate_work",  # two OL works that are the same book
    "wrong_data",  # the stored mapping is simply wrong
    "not_in_open_library",
)

Verdict = Literal["match", "no_match", "ambiguous"]


class EvalBook(BaseModel):
    book_id: int
    title: str
    subtitle: str | None = None
    author_names: list[str] = Field(default_factory=list)
    first_published_year: int | None = None
    isbn13: list[str] = Field(default_factory=list)
    isbn10: list[str] = Field(default_factory=list)
    asin: list[str] = Field(default_factory=list)
    goodreads_id: list[str] = Field(default_factory=list)  # [GOODREADS]
    existing_ol_work_keys: list[str] = Field(default_factory=list)
    existing_ol_author_keys: list[str] = Field(default_factory=list)


class EvalCandidate(BaseModel):
    work_key: str
    rules: list[str] = Field(default_factory=list)


class EvalLabel(BaseModel):
    verdict: Verdict
    work_key: str | None = None
    identity_rule: str | None = None
    rationale: str = Field(min_length=10)
    labeled_at: datetime.date
    labeled_against_dump_date: str

    @model_validator(mode="after")
    def check_verdict_consistency(self) -> EvalLabel:
        if self.identity_rule is not None and self.identity_rule not in IDENTITY_RULES:
            raise ValueError(f"unknown identity_rule {self.identity_rule!r}")
        if self.verdict == "match" and not self.work_key:
            raise ValueError("a match verdict requires a work_key")
        if self.verdict == "no_match":
            if self.work_key:
                raise ValueError("a no_match verdict must not carry a work_key")
            if self.identity_rule != "not_in_open_library":
                raise ValueError("a no_match verdict uses identity_rule 'not_in_open_library'")
        return self


class EvalCase(BaseModel):
    case_id: str
    stratum: str
    book: EvalBook
    candidates_shown: list[EvalCandidate] = Field(default_factory=list)
    label: EvalLabel

    @model_validator(mode="after")
    def check_stratum(self) -> EvalCase:
        if self.stratum not in STRATA:
            raise ValueError(f"unknown stratum {self.stratum!r}")
        return self

    @property
    def found_outside_blocking(self) -> bool:
        """True when the labeler entered a work key that no blocking rule produced.

        These cases are the most valuable in the set: they are the only evidence
        of a candidate-recall failure. Without them, recall measured on this set
        is 100% by construction.
        """
        if self.label.verdict != "match" or not self.label.work_key:
            return False
        return self.label.work_key not in {c.work_key for c in self.candidates_shown}
