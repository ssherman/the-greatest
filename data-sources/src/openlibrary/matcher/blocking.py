"""Stage 1: generate candidates. Never decides anything.

Six rules, UNIONED. Measured on 122,970 usable books:

    title-fp only   >=1: 82.2%   unique: 26.5%   median 3   p90 42   max 6,124
    author-blocked  >=1: 63.4%   unique: 38.0%   median 1   p90 4    max 407
    UNION           >=1: 82.2%          exactly one: 44.6%

So author blocking is a PRECISION rule and title blocking is a RECALL rule.
Neither gates the other; an author-resolution failure costs rules 3 and 5 and
leaves 1, 4 and 6 firing.

Every rule has a volume guard. A rule that would return too much does not fire
and says so: a visible gap beats a query that never returns. The one
exception is rule 5, whose own cap is `MAX_SHELF_SIZE` rather than
`MAX_CANDIDATES_PER_RULE`: once an author resolves, the scorer -- not
blocking -- is meant to read the whole shelf.

A tripped guard is reported two ways (ruling R59). `guards_tripped` names
every rule that declined to fire, for any reason; `volume_guards_tripped` is
the subset that declined because there WAS something and it was too much to
fetch -- a cap or the title-frequency limit. The difference matters when
nothing else fires: zero candidates with a volume guard tripped means "found,
refused" and the decider abstains; zero candidates with only the empty/short
fingerprint `title_fp` guard means "nothing to find" and it rejects.
"""

from __future__ import annotations

import re

import duckdb
from pydantic import BaseModel, Field, field_validator

from common.normalize import (
    MIN_BLOCKING_FP_LENGTH,
    fingerprint,
    identifier_pairs,
    title_fingerprints,
)
from openlibrary.pipeline.duck import load_rows
from openlibrary.pipeline.paths import ArtifactPaths

RULES = (
    "identifier",
    "existing_key",
    "author_title_fp",
    "title_fp",
    "author_shelf",
    "trigram",
)

MAX_CANDIDATES_PER_RULE = 200
MAX_TITLE_FP_FREQ = 50
MAX_SHELF_SIZE = 500
TRIGRAM_MIN_SIMILARITY = 0.55


# The artifact's `editions.language_code` vocabulary is MARC (eng, ger, fre,
# spa, ...), three lowercase letters -- not ISO 639-1 (en, de, fr, es). A
# query carrying an ISO code would compare as "disagree" against every
# edition and never as "agree" (ruling R61).
_MARC_LANGUAGE_CODE = re.compile(r"^[a-z]{3}$")


class BlockingQuery(BaseModel):
    """One book, as the matcher sees it.

    `language` must be a MARC language code (`^[a-z]{3}$`) or None: the
    artifact's `editions.language_code` is MARC and `features.extract` compares
    the two strings for equality. The CALLER maps whatever it holds (an ISO
    639-1 `en`, a Rails `Language` row) to MARC before constructing the query;
    an ISO code is rejected here rather than silently scoring as disagreement.
    """

    title: str
    subtitle: str | None = None
    author_names: list[str] = Field(default_factory=list)
    year: int | None = None
    language: str | None = None
    isbn13: list[str] = Field(default_factory=list)
    isbn10: list[str] = Field(default_factory=list)
    asin: list[str] = Field(default_factory=list)
    goodreads_id: list[str] = Field(default_factory=list)  # [GOODREADS]
    oclc: list[str] = Field(default_factory=list)
    lccn: list[str] = Field(default_factory=list)
    existing_ol_key: str | None = None

    @field_validator("language")
    @classmethod
    def _language_is_a_marc_code(cls, value: str | None) -> str | None:
        if value is not None and not _MARC_LANGUAGE_CODE.match(value):
            raise ValueError(
                f"language must be a 3-letter lowercase MARC code (eng, ger, fre, spa), "
                f"got {value!r}; map ISO codes before building the query"
            )
        return value


class BlockingResult(BaseModel):
    candidates: dict[str, list[str]] = Field(default_factory=dict)
    guards_tripped: list[str] = Field(default_factory=list)
    # R59: the rules whose volume CAP tripped -- identifier, author_title_fp,
    # title_fp (frequency or cap, NOT the empty/short-fingerprint case),
    # author_shelf. Always a subset of `guards_tripped`.
    volume_guards_tripped: list[str] = Field(default_factory=list)

    @property
    def identifier_hits(self) -> frozenset[str]:
        """The works our identifiers reached (rule 1) -- the set `features.extract`
        and `features.conflicts` compare each candidate against (R35)."""
        return frozenset(k for k, rules in self.candidates.items() if "identifier" in rules)


def _add(result: BlockingResult, work_key: str, rule: str) -> None:
    rules = result.candidates.setdefault(work_key, [])
    if rule not in rules:
        rules.append(rule)


def _volume_guard(result: BlockingResult, rule: str) -> None:
    """Record a cap/frequency guard in BOTH lists (R59)."""
    result.guards_tripped.append(rule)
    result.volume_guards_tripped.append(rule)


def generate_candidates(
    con: duckdb.DuckDBPyConnection,
    paths: ArtifactPaths,
    query: BlockingQuery,
) -> BlockingResult:
    result = BlockingResult()
    fps = title_fingerprints(query.title)
    variants = [fp for fp in {fps.full, fps.nosub, fps.noart} if len(fp) >= MIN_BLOCKING_FP_LENGTH]
    author_fps = [fp for fp in (fingerprint(n) for n in query.author_names) if fp]

    # Rule 1 -- identifiers. Deterministic; may legitimately return several works.
    #
    # `i.work_key` is whatever the EDITION recorded, and editions go stale
    # (ruling R41): measured on 2026-07-31, `identifiers.work_key` is a
    # redirect SOURCE for 270 distinct works (9,216 rows) and absent from
    # `works` altogether for 294. Returning such a key verbatim is worse than
    # a miss: `load_work_views` has no view for it, so it is dropped as a
    # candidate -- but it stays in `identifier_hits`, and under R35 every REAL
    # candidate (including the redirect's target, i.e. the true work) then
    # reads as an identifier CONFLICT and the decider abstains. So the key is
    # resolved through `redirects` here (entity = 'work', cycles excluded)
    # and anything still absent from `works` is dropped before it can poison
    # the hit set. `work_authors` has 0 stale keys, so rules 3 and 5 need no
    # such step.
    identifiers = identifier_pairs(
        isbn13=query.isbn13,
        isbn10=query.isbn10,
        asin=query.asin,
        goodreads_id=query.goodreads_id,
        oclc=query.oclc,
        lccn=query.lccn,
    )
    if identifiers:
        load_rows(con, "q_ids", [("id_type", "VARCHAR"), ("value", "VARCHAR")], identifiers)
        rows = con.execute(
            f"""
            SELECT DISTINCT COALESCE(r.terminal_key, i.work_key) AS work_key
            FROM '{paths.table("identifiers")}' i
            JOIN q_ids q ON q.id_type = i.id_type AND q.value = i.value
            LEFT JOIN '{paths.table("redirects")}' r
              ON r.source_key = i.work_key AND r.entity = 'work' AND NOT r.is_cycle
            WHERE i.work_key IS NOT NULL
              AND COALESCE(r.terminal_key, i.work_key)
                  IN (SELECT work_key FROM '{paths.table("works")}')
            LIMIT {MAX_CANDIDATES_PER_RULE + 1}
            """
        ).fetchall()
        if len(rows) > MAX_CANDIDATES_PER_RULE:
            _volume_guard(result, "identifier")
        else:
            for (work_key,) in rows:
                _add(result, work_key, "identifier")

    # Rule 2 -- the stored OL key, redirect-resolved. A HINT, weighted like any
    # other evidence: 9.9% are dead and 380 are attached to several books.
    if query.existing_ol_key:
        row = con.execute(
            f"""
            SELECT COALESCE(r.terminal_key, ?) FROM (SELECT 1) t
            LEFT JOIN '{paths.table("redirects")}' r
              ON r.source_key = ? AND r.entity = 'work' AND NOT r.is_cycle
            """,
            [query.existing_ol_key, query.existing_ol_key],
        ).fetchone()
        if row and row[0]:
            (exists,) = con.execute(
                f"SELECT count(*) FROM '{paths.table('works')}' WHERE work_key = ?", [row[0]]
            ).fetchone()
            if exists:
                _add(result, row[0], "existing_key")

    # Rule 3 -- resolved author + any title fingerprint variant. Measured p90 = 4.
    if author_fps and variants:
        load_rows(con, "q_author_fps", [("name_fp", "VARCHAR")], [(fp,) for fp in author_fps])
        load_rows(con, "q_title_fps", [("title_fp", "VARCHAR")], [(fp,) for fp in variants])
        rows = con.execute(
            f"""
            SELECT DISTINCT w.work_key
            FROM '{paths.table("author_names")}' an
            JOIN q_author_fps q USING (name_fp)
            JOIN '{paths.table("work_authors")}' wa ON wa.author_key = an.author_key
            JOIN '{paths.table("works")}' w ON w.work_key = wa.work_key
            WHERE w.title_fp       IN (SELECT title_fp FROM q_title_fps)
               OR w.title_fp_nosub IN (SELECT title_fp FROM q_title_fps)
               OR w.title_fp_noart IN (SELECT title_fp FROM q_title_fps)
            LIMIT {MAX_CANDIDATES_PER_RULE + 1}
            """
        ).fetchall()
        if len(rows) > MAX_CANDIDATES_PER_RULE:
            _volume_guard(result, "author_title_fp")
        else:
            for (work_key,) in rows:
                _add(result, work_key, "author_title_fp")

    # Rule 4 -- title fingerprint alone. The frequency guard is VISIBLE
    # (ruling R32): the query returns rows regardless of frequency, ordered
    # so legitimate rows (<= MAX_TITLE_FP_FREQ per variant, so <= 150 total
    # across the three variants) always sort ahead of a suppressed common
    # title and fit under the LIMIT. Python decides admission per row and
    # whether to record the guard from what came back. This is the
    # data-driven fix for the 604,144-row explosion, and it also catches
    # "selected poems" and "collected works", which pass any length check.
    #
    # `guards_tripped` may carry "title_fp" for two different reasons: an
    # empty/too-short fingerprint (the `else` branch below, e.g. "!!!") or a
    # common title suppressed here. Only the second is a VOLUME guard and
    # goes into `volume_guards_tripped` too (R59); rule 6 below also needs
    # the distinction, so `suppressed_common_title` tracks the second reason
    # separately rather than testing `"title_fp" in guards_tripped` (ruling
    # R39, amended: a too-short fingerprint has zero exact hits and rule 6's
    # reasoning does not apply to it).
    #
    # This joins against all three title fingerprint variants (full/nosub/
    # noart). `eval/build_pool.py`'s own copy of rule 4 joins the full
    # fingerprint only, because the evaluation pool is frozen and already
    # labeled -- a case whose only match is a nosub/noart variant is a
    # candidate the pool's strata never saw. The evaluation harness measures
    # recall against labels, not against pool candidates, so this wider rule
    # can only raise measured recall, never lower it; see build_pool.py's
    # module docstring for the other half of this note.
    suppressed_common_title = False
    if variants:
        load_rows(con, "q_title_fps4", [("title_fp", "VARCHAR")], [(fp,) for fp in variants])
        rows = con.execute(
            f"""
            SELECT DISTINCT w.work_key, w.title_fp_freq FROM '{paths.table("works")}' w
            JOIN q_title_fps4 q ON q.title_fp = w.title_fp
            ORDER BY w.title_fp_freq
            LIMIT {MAX_CANDIDATES_PER_RULE + 1}
            """
        ).fetchall()
        if any(freq > MAX_TITLE_FP_FREQ for _, freq in rows) or len(rows) > MAX_CANDIDATES_PER_RULE:
            _volume_guard(result, "title_fp")
            suppressed_common_title = True
        for work_key, freq in rows:
            if freq <= MAX_TITLE_FP_FREQ:
                _add(result, work_key, "title_fp")
    else:
        # An empty or too-short fingerprint: nothing to look up, so a guard
        # but NOT a volume guard (R59) -- there is no "something" here that
        # was refused.
        result.guards_tripped.append("title_fp")

    # Rule 5 -- the author's whole shelf. Once an author resolves, no search is
    # needed: fetch 5-500 works and let the scorer read every title.
    if author_fps:
        load_rows(con, "q_author_fps5", [("name_fp", "VARCHAR")], [(fp,) for fp in author_fps])
        rows = con.execute(
            f"""
            SELECT DISTINCT wa.work_key
            FROM '{paths.table("author_names")}' an
            JOIN q_author_fps5 q USING (name_fp)
            JOIN '{paths.table("work_authors")}' wa ON wa.author_key = an.author_key
            LIMIT {MAX_SHELF_SIZE + 1}
            """
        ).fetchall()
        if len(rows) > MAX_SHELF_SIZE:
            _volume_guard(result, "author_shelf")
        else:
            for (work_key,) in rows:
                _add(result, work_key, "author_shelf")

    # Rule 6 -- trigram fallback, ONLY for the ~18% with no exact hit anywhere.
    # Fuzzy retrieval serves a fallback path, not a pillar; this is why the
    # design does not carry a search engine. `not suppressed_common_title` is
    # required alongside `not result.candidates`: a title rule 4 suppressed
    # for frequency HAD exact hits, so falling through to rule 6 there would
    # resurrect ~200 near-identical works under a fuzzy label and defeat the
    # guard rule 4 just tripped. A genuinely short title (e.g. "Zen") also
    # trips rule 4's "title_fp" guard, but for the OTHER reason -- it has no
    # exact hits at all -- so that case must still reach rule 6; testing
    # `suppressed_common_title` rather than `guards_tripped` membership is
    # what keeps the two cases apart.
    #
    # Same volume-guard contract as rules 1, 3, 4 and 5 (ruling R64): query for
    # cap + 1 and, if more come back, admit nothing and record the guard
    # instead. DuckDB's `jaccard` compares character SETS, not substrings, so
    # more than MAX_CANDIDATES_PER_RULE works tying at 1.0 is a known common
    # case -- 973 works tied against one real query in the measured corpus --
    # and the old bare `LIMIT MAX_CANDIDATES_PER_RULE` hid that overflow,
    # silently admitting an arbitrary 200 of the ties and never telling the
    # decider the fuzzy search was incomplete (`no_candidates-030`: the
    # labelled work sat outside that arbitrary 200). An unbounded fuzzy search
    # must not look authoritative any more than an unbounded exact one does.
    # Wanted side effect: under the cap the candidate set is now
    # deterministic, which closes the "rule 6 is nondeterministic" carry
    # forward from the v2 measurement -- that flakiness was rule 6 falling
    # back to DuckDB's arbitrary `LIMIT` ordering on an overflowing search,
    # not something inherent to the rule.
    if not result.candidates and fps.full and not suppressed_common_title:
        rows = con.execute(
            f"""
            SELECT work_key FROM '{paths.table("works")}'
            WHERE title_fp <> ''
              AND jaccard(title_fp, ?) >= {TRIGRAM_MIN_SIMILARITY}
            ORDER BY jaccard(title_fp, ?) DESC
            LIMIT {MAX_CANDIDATES_PER_RULE + 1}
            """,
            [fps.full, fps.full],
        ).fetchall()
        if len(rows) > MAX_CANDIDATES_PER_RULE:
            _volume_guard(result, "trigram")
        else:
            for (work_key,) in rows:
                _add(result, work_key, "trigram")

    return result
