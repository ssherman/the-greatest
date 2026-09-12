"""Regenerate the fixture corpus from the real dumps.

Run manually; the output is committed. Selection is by explicit key and by
explicitly named weirdness, never by "the first N lines", so the corpus stays
stable and every line is here for a stated reason.

    uv run python tests/fixtures/extract_fixtures.py \
        --works /mnt/e/ol_dump_works_2026-07-31.txt.gz \
        --authors /mnt/e/ol_dump_authors_2026-07-31.txt.gz \
        --editions /mnt/c/Users/shane/Downloads/ol_dump_editions_2026-07-31.txt.gz \
        --redirects /home/shane/ol-data/incoming/2026-07-31/ol_dump_redirects_2026-07-31.txt.gz \
        --ratings /home/shane/ol-data/incoming/2026-07-31/ol_dump_ratings_2026-07-31.txt.gz \
        --reading-log /home/shane/ol-data/incoming/2026-07-31/ol_dump_reading-log_2026-07-31.txt.gz
"""

from __future__ import annotations

import argparse
import gzip
import json
import re
from pathlib import Path

OUT = Path(__file__).parent

# Works named in the spec's collision analysis. These are the seed of both the
# fixture corpus and the evaluation set's hardest stratum.
# The omnibus seed was originally OL15331408W ("Eye in the Pyramid" / "Golden
# Apple" / "Leviathan"), the spec's worked example of an omnibus-vs-parts
# collision. Open Library merged that key into OL3809593W on 2026-01-04 --
# OL15331408W is itself one of the 3,064 (9.9%) stored keys the design
# predicts no longer resolve. OL3809593W carries the same content (title
# "The Illuminatus! Trilogy"; its own description field points back at
# OL15331408W) and is live in the 2026-07-31 dump, so it seeds works.txt.
# OL15331408W is carried separately, as a real redirect line, by
# collect_redirects() below -- it is more valuable as a genuine stale key
# than as a work that no longer exists.
SEED_WORKS = [
    "OL3809593W",  # omnibus: Eye in the Pyramid / Golden Apple / Leviathan (formerly OL15331408W)
    "OL2014226W",  # 99 Francs / 99 Франков -- one work, two languages
    "OL81205W",  # Poems of D. H. Lawrence / The Other -- wrong data
    "OL8331643W",  # Blood River / Blood River -- real duplicate
]

# A sample of real data is almost all happy path, and this corpus was one:
# measured against the build it produces, it had 0 works sharing a title
# fingerprint, 0 ISBNs on more than one work, 0 non-Latin-SCRIPT titles, 0
# work-entity dangling redirects and 0 works with a declared year but no
# editions. Every guard that exists to catch one of those therefore had no test
# that could fail -- which is how a `non_latin_title` predicate that could not
# match Greek or Cyrillic shipped into a 450-case labelling pool.
#
# These works are here to be the NEGATIVE class. They are real records, chosen
# by querying the built artifact for the property named beside each one.
NEGATIVE_CLASS_WORKS = [
    # One book, two OL works, two author records ("Leonard W. Levy" and
    # "Leonard Williams Levy"), and ISBN 9780028972459 on editions of both.
    # Gives the corpus its only reused ISBN and its only repeated title
    # fingerprint ("the establishment clause").
    "OL108593W",
    "OL269642W",
    # "The Jeeves Omnibus : No.4" / "The Jeeves Omnibus": the SUBTITLE variant
    # of the first equals the full fingerprint of the second, which is the
    # collision title_fp_nosub exists to catch. OL37903252W also has no
    # authors at all -- the OL-side half of the author_less_work stratum.
    "OL37903252W",
    "OL286576W",
    # "The Third Book of Swords" / "Third Book of Swords": the ARTICLE variant
    # of the first equals the full fingerprint of the second.
    "OL11312814W",
    "OL100114W",
    # 武田信玄のすべて -- a pure-CJK title, whose fingerprint is the EMPTY
    # STRING. The design's claim that "the fingerprint erases these" asserted
    # against a real row rather than assumed.
    "OL45112058W",
    # "don kichotis / δον κιχώτης" -- Greek and Latin in one title, so it
    # fingerprints to "don kichotis" and stays long enough to be a blocking
    # key. This is the only shape non_latin_title can actually claim: a title
    # in one non-Latin script alone fingerprints to nothing and is claimed by
    # degenerate_title first.
    "OL31397951W",
    # "The ascendant organisation" -- a first_publish_date and ZERO editions
    # anywhere in the dump. NOTE: a seed work with no editions means the
    # editions pass can never satisfy its stop condition and scans to EOF. That
    # is already true of OL1017765W and OL10445829W, and scan() documents it as
    # the correct fallback.
    "OL3524373W",
]

# Each predicate takes the parsed JSON and returns True when the line is an
# example we need. `quota` caps how many of each we keep.
WORK_PREDICATES = {
    "description_is_object": (lambda d: isinstance(d.get("description"), dict), 3),
    "description_is_string": (lambda d: isinstance(d.get("description"), str), 3),
    "no_authors": (lambda d: not d.get("authors"), 3),
    "author_entry_without_author_key": (
        lambda d: any("author" not in a for a in (d.get("authors") or []) if isinstance(a, dict)),
        3,
    ),
    "degenerate_title": (
        lambda d: len(re.sub(r"[^a-z0-9 ]", " ", (d.get("title") or "").lower()).strip()) < 4,
        5,
    ),
    # `ord(ch) > 0x2000` was wrong in both directions and this file carried the
    # same bug that shipped in build_pool.py. The Latin blocks end at U+024F,
    # so Greek (U+0370) and Cyrillic (U+0400) sit BELOW 0x2000 and could never
    # match; general punctuation sits above it, so the five works this selected
    # matched on a right single quote, a euro sign and the combining half marks
    # in "i︠a︡" -- all pure Latin. `.isalpha()` is what excludes the punctuation.
    # The NEGATIVE_CLASS_WORKS seeds carry the real scripts regardless of what
    # this predicate happens to find first.
    "non_latin_title": (
        lambda d: any(ch.isalpha() and ord(ch) > 0x024F for ch in (d.get("title") or "")),
        5,
    ),
    "has_subjects_and_year": (
        lambda d: bool(d.get("subjects")) and bool(d.get("first_publish_date")),
        5,
    ),
    "has_subtitle": (lambda d: bool(d.get("subtitle")), 3),
}

AUTHOR_PREDICATES = {
    "has_alternate_names": (lambda d: bool(d.get("alternate_names")), 5),
    "messy_birth_date": (
        lambda d: bool(d.get("birth_date")) and not str(d["birth_date"]).isdigit(),
        5,
    ),
    "no_name": (lambda d: not d.get("name"), 2),
    "plain": (lambda d: bool(d.get("name")) and bool(d.get("birth_date")), 5),
}

# OL15331408W (the pre-merge omnibus key -- see SEED_WORKS above) still exists as a real
# redirect record in the 2026-07-31 redirects dump. It is carried explicitly, by key, rather
# than left to collect_redirects()'s general selection heuristic, so the fixture always has a
# genuine (not synthetic) example of a stale/merged key resolving via one redirect hop.
STALE_OMNIBUS_REDIRECT_KEY = "/works/OL15331408W"

# A /works/ redirect whose terminal does not exist in the works dump at all
# (OL16808392W is absent from all 41.5M works). Before this, all 69 dangling
# redirects in the corpus were AUTHORS, so redirects.py's work-entity dangling
# branch -- the one the matcher will lean on when a stored key resolves to
# nothing -- had no positive case anywhere.
DANGLING_WORK_REDIRECT_KEY = "/works/OL26204513W"

# MAX_TITLE_FP_FREQ is 50, so exercising blocking rule 4's frequency guard --
# the guard that exists because one degenerate key produced a 604,144-row join
# -- needs 51 works sharing one title fingerprint. These are SYNTHETIC and say
# so in their JSON. The real dump has 1,981 works titled "Selected Poems", but
# seeding 51 of them by key would drag 51 unrelated authors into authors.txt
# and shift the corpus's author coverage, for a property that is purely a
# count. They reuse an author key the corpus already carries, so author
# coverage is unchanged.
#
# The key range matters. The first attempt used OL9990001W..OL9990051W, which
# are REAL Open Library work keys -- the highest real numeric part in the
# 2026-07-31 dump is 45,845,863, so anything with eight or fewer digits can
# collide. It did: the editions pass collects every edition of every fixture
# work, so 51 real editions were pulled in and attached to synthetic works,
# quietly giving them publish years and ISBNs. These keys sit just above the
# synthetic cycle pair, four digits clear of the real maximum, and
# test_fixture_corpus.py asserts no edition ever attaches to one.
SYNTHETIC_FREQUENT_TITLE = "Selected Poems"
SYNTHETIC_FREQUENT_TITLE_COUNT = 51
SYNTHETIC_FREQUENT_AUTHOR_KEY = "/authors/OL32259A"
SYNTHETIC_FREQUENT_KEY_BASE = 999_999_100


def synthetic_frequent_title_works() -> list[str]:
    lines = []
    for index in range(1, SYNTHETIC_FREQUENT_TITLE_COUNT + 1):
        key = f"/works/OL{SYNTHETIC_FREQUENT_KEY_BASE + index}W"
        doc = {
            "key": key,
            "title": SYNTHETIC_FREQUENT_TITLE,
            "authors": [
                {
                    "type": {"key": "/type/author_role"},
                    "author": {"key": SYNTHETIC_FREQUENT_AUTHOR_KEY},
                }
            ],
            "type": {"key": "/type/work"},
            "_synthetic": (
                f"one of {SYNTHETIC_FREQUENT_TITLE_COUNT} works sharing one title "
                "fingerprint, so title_fp_freq exceeds MAX_TITLE_FP_FREQ"
            ),
        }
        lines.append(
            f"/type/work\t{key}\t1\t2020-01-01T00:00:00.000000\t"
            + json.dumps(doc, ensure_ascii=False)
            + "\n"
        )
    return lines


def _isbn_check_digit_is_wrong(raw) -> bool:
    """True for a syntactically valid ISBN whose check digit does not compute.

    Deliberately its own arithmetic rather than a call into
    `common.normalize`: this predicate SELECTS the rows that test
    `isbn_checksum_ok_sql`, and selecting them with the code under test would
    make the fixture agree with the implementation by construction.
    """
    cleaned = "".join(ch for ch in str(raw) if ch.isalnum()).upper()
    if len(cleaned) == 10 and cleaned[:9].isdigit() and (cleaned[9].isdigit() or cleaned[9] == "X"):
        total = sum((10 - i) * int(ch) for i, ch in enumerate(cleaned[:9]))
        remainder = (11 - (total % 11)) % 11
        return ("X" if remainder == 10 else str(remainder)) != cleaned[9]
    if len(cleaned) == 13 and cleaned.isdigit():
        total = sum(int(ch) * (1 if i % 2 == 0 else 3) for i, ch in enumerate(cleaned[:12]))
        return str((10 - (total % 10)) % 10) != cleaned[12]
    return False


EDITION_PREDICATES = {
    "no_works": (lambda d: not d.get("works"), 3),
    # 76,242 ISBN-10 and 30,221 ISBN-13 rows in the real build fail their check
    # digit. Without one of each here, `identifiers.checksum_ok` has no `false`
    # anywhere in the corpus and its test can only assert `>= 0`.
    "bad_isbn10_check_digit": (
        lambda d: any(_isbn_check_digit_is_wrong(v) for v in (d.get("isbn_10") or [])),
        2,
    ),
    "bad_isbn13_check_digit": (
        lambda d: any(_isbn_check_digit_is_wrong(v) for v in (d.get("isbn_13") or [])),
        2,
    ),
    "marc_filler_date": (
        lambda d: bool(d.get("publish_date")) and not re.search(r"\d{4}", str(d["publish_date"])),
        5,
    ),
    "has_goodreads_id": (lambda d: "goodreads" in (d.get("identifiers") or {}), 5),
    "has_oclc_and_lccn": (lambda d: bool(d.get("oclc_numbers")) and bool(d.get("lccn")), 5),
    "amazon_source_record": (
        lambda d: any(str(s).startswith("amazon:") for s in (d.get("source_records") or [])),
        5,
    ),
    "full_bibliographic": (
        lambda d: (
            bool(d.get("isbn_13")) and bool(d.get("languages")) and bool(d.get("number_of_pages"))
        ),
        5,
    ),
}


def scan(
    path: Path,
    key_prefix: str,
    seeds: set[str],
    predicates: dict,
    seed_by_work: set[str] | None = None,
):
    kept: list[str] = []
    counts = {name: 0 for name in predicates}
    seen_seeds: set[str] = set()
    # Editions only: which of `seed_by_work`'s works we've collected at least one edition
    # for so far. Unused (stays empty) for the works/authors passes.
    seed_works_found: set[str] = set()
    with gzip.open(path, "rt", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            parts = line.split("\t", 4)
            if len(parts) < 5:
                continue
            key = parts[1].removeprefix(key_prefix)
            try:
                doc = json.loads(parts[4])
            except Exception:
                continue

            if key in seeds and key not in seen_seeds:
                seen_seeds.add(key)
                kept.append(line)
                continue

            if seed_by_work is not None:
                works = {w.get("key", "").removeprefix("/works/") for w in (doc.get("works") or [])}
                hit = works & seed_by_work
                if hit:
                    kept.append(line)
                    seed_works_found |= hit
                    continue

            for name, (predicate, quota) in predicates.items():
                if counts[name] >= quota:
                    continue
                try:
                    hit = predicate(doc)
                except Exception:
                    hit = False
                if hit:
                    counts[name] += 1
                    kept.append(line)
                    break

            quotas_met = all(counts[n] >= q for n, (_, q) in predicates.items())
            if seed_by_work is not None:
                # Editions pass: `seeds` is empty here, so "seen_seeds >= seeds" would be
                # vacuously true and the scan would stop the moment predicate quotas fill --
                # within the first few hundred thousand lines of a 12.5 GB file. But the
                # seed works' editions sit at arbitrary offsets in that file, so stopping
                # early can ship a corpus with zero editions for a seed work whose editions
                # simply hadn't been reached yet. Require at least one edition collected for
                # every seed work in `seed_by_work` too. If some seed work genuinely has no
                # editions anywhere in the dump, this never becomes true and the loop runs to
                # EOF -- a complete scan is the correct fallback in that case.
                stop = quotas_met and seed_by_work <= seed_works_found
            else:
                stop = seen_seeds >= seeds and quotas_met
            if stop:
                break
    missing = [n for n, (_, q) in predicates.items() if counts[n] < q]
    if missing:
        print(f"  WARNING: quota not met for {missing}")
    print(f"  seeds found: {sorted(seen_seeds)}")
    if seed_by_work is not None:
        missing_seed_works = seed_by_work - seed_works_found
        if missing_seed_works:
            print(f"  WARNING: no editions for seed works: {sorted(missing_seed_works)}")
        else:
            print(f"  editions found for every seed work: {sorted(seed_by_work)}")
    return kept


def main() -> None:
    ap = argparse.ArgumentParser()
    for name in ("works", "authors", "editions", "redirects", "ratings", "reading-log"):
        ap.add_argument(f"--{name}", type=Path, required=True)
    args = ap.parse_args()

    seeds = set(SEED_WORKS) | set(NEGATIVE_CLASS_WORKS)

    print("works...")
    work_lines = scan(args.works, "/works/", seeds, WORK_PREDICATES)
    work_lines.extend(synthetic_frequent_title_works())
    (OUT / "works.txt").write_text("".join(work_lines), encoding="utf-8")

    work_keys = {ln.split("\t", 2)[1].removeprefix("/works/") for ln in work_lines}

    print("editions...")
    edition_lines = scan(
        args.editions, "/books/", set(), EDITION_PREDICATES, seed_by_work=work_keys
    )
    (OUT / "editions.txt").write_text("".join(edition_lines), encoding="utf-8")

    author_keys: set[str] = set()
    for ln in work_lines:
        doc = json.loads(ln.split("\t", 4)[4])
        for entry in doc.get("authors") or []:
            key = (entry.get("author") or {}).get("key", "") if isinstance(entry, dict) else ""
            if key:
                author_keys.add(key.removeprefix("/authors/"))

    print("authors...")
    author_lines = scan(args.authors, "/authors/", author_keys, AUTHOR_PREDICATES)
    (OUT / "authors.txt").write_text("".join(author_lines), encoding="utf-8")

    print("redirects...")
    redirect_lines = collect_redirects(args.redirects)
    (OUT / "redirects.txt").write_text("".join(redirect_lines), encoding="utf-8")

    print("ratings / reading-log...")
    for arg_name, out_name in (("ratings", "ratings.txt"), ("reading-log", "reading-log.txt")):
        rows = []
        with gzip.open(
            getattr(args, arg_name.replace("-", "_")), "rt", encoding="utf-8", errors="replace"
        ) as fh:
            for line in fh:
                key = line.split("\t", 1)[0].removeprefix("/works/")
                if key in work_keys:
                    rows.append(line)
                if len(rows) >= 200:
                    break
        (OUT / out_name).write_text("".join(rows), encoding="utf-8")

    for name in ("works", "authors", "editions", "redirects", "ratings", "reading-log"):
        path = OUT / f"{name}.txt"
        print(f"{path.name}: {sum(1 for _ in path.open())} lines, {path.stat().st_size:,} bytes")


def collect_redirects(path: Path) -> list[str]:
    """The stale omnibus key, a 1-hop redirect, a >=3-hop chain, an author redirect, a dangling
    one, and a synthetic cycle.

    STALE_OMNIBUS_REDIRECT_KEY (OL15331408W) is carried explicitly: it is SEED_WORKS' real
    predecessor key, merged into OL3809593W on 2026-01-04, and gives the redirect-resolution
    path a genuine stale key instead of only ever seeing live ones.

    A cycle is appended synthetically if the dump contains none: the cycle gate
    (Task 9) needs a positive case, and there is no honest way to test it
    against data that does not contain one.
    """
    by_key: dict[str, str] = {}
    lines: dict[str, str] = {}
    kept: list[str] = []
    with gzip.open(path, "rt", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            parts = line.split("\t", 4)
            if len(parts) < 5:
                continue
            try:
                doc = json.loads(parts[4])
            except Exception:
                continue
            src, dst = doc.get("key"), doc.get("location")
            if not src or not dst:
                continue
            by_key[src] = dst
            lines[src] = line

    for explicit in (STALE_OMNIBUS_REDIRECT_KEY, DANGLING_WORK_REDIRECT_KEY):
        if explicit in lines:
            kept.append(lines[explicit])
        else:
            print(f"  WARNING: {explicit} not found in the redirects dump")

    chains = []
    for src in by_key:
        depth, cursor, path_keys = 0, src, [src]
        while cursor in by_key and depth < 10:
            cursor = by_key[cursor]
            path_keys.append(cursor)
            depth += 1
        if depth >= 3 and len(set(path_keys)) == len(path_keys):
            chains.append(path_keys)
        if len(chains) >= 2:
            break

    for chain in chains:
        for key in chain:
            if key in lines and lines[key] not in kept:
                kept.append(lines[key])

    # `not in kept` guards below: STALE_OMNIBUS_REDIRECT_KEY (and any chain member) may already
    # be present, and this loop has no other way to know that.
    for src, dst in list(by_key.items())[:400]:
        if (
            src.startswith("/works/")
            and dst not in by_key
            and len(kept) < 60
            and lines[src] not in kept
        ):
            kept.append(lines[src])
        if src.startswith("/authors/") and len(kept) < 70 and lines[src] not in kept:
            kept.append(lines[src])

    kept.append(
        "/type/redirect\t/works/OL999999001W\t2\t2020-01-01T00:00:00.000000\t"
        '{"key": "/works/OL999999001W", "location": "/works/OL999999002W", '
        '"type": {"key": "/type/redirect"}, "_synthetic": "cycle half 1 of 2"}\n'
    )
    kept.append(
        "/type/redirect\t/works/OL999999002W\t2\t2020-01-01T00:00:00.000000\t"
        '{"key": "/works/OL999999002W", "location": "/works/OL999999001W", '
        '"type": {"key": "/type/redirect"}, "_synthetic": "cycle half 2 of 2"}\n'
    )
    return kept


if __name__ == "__main__":
    main()
