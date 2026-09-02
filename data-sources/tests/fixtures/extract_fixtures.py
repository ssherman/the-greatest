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
    "non_latin_title": (
        lambda d: any(ord(ch) > 0x2000 for ch in (d.get("title") or "")),
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


EDITION_PREDICATES = {
    "no_works": (lambda d: not d.get("works"), 3),
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

    seeds = set(SEED_WORKS)

    print("works...")
    work_lines = scan(args.works, "/works/", seeds, WORK_PREDICATES)
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

    if STALE_OMNIBUS_REDIRECT_KEY in lines:
        kept.append(lines[STALE_OMNIBUS_REDIRECT_KEY])
    else:
        print(f"  WARNING: {STALE_OMNIBUS_REDIRECT_KEY} not found in the redirects dump")

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
