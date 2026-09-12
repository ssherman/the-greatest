# Books: which identifiers actually reach Open Library

**Measured 2026-09-04** against the `2026-07-31` Open Library artifact and a
development database refreshed from production (157,805 exported books).

This is a matcher design input, not a repair list. It answers one question:
when the matcher has an identifier in hand, how often is that identifier
present in Open Library at all?

## Results

| Identifier | Books holding one | Distinct values | Values in OL | Value coverage | Books whose id **reaches a work** | Book coverage | Lost to orphan editions |
|---|---:|---:|---:|---:|---:|---:|---:|
| `isbn10` | 136,650 | 214,747 | 173,393 | 80.7% | 117,756 | **86.2%** | 315 |
| `isbn13` | 133,057 | 166,736 | 138,947 | 83.3% | 113,324 | **85.2%** | 336 |
| `goodreads` | 151,935 | 193,915 | 58,352 | 30.1% | 50,566 | 33.3% | 278 |
| `asin` | 30,507 | 76,333 | 4,681 | 6.1% | 3,676 | **12.0%** | 0 |

**Books whose identifier reaches an Open Library work: 119,543 of 157,805 —
75.8%.** Another 318 books hold an identifier Open Library has but cannot use.

### Present in Open Library is not the same as usable

**1,947,922 Open Library editions carry no work key**, and **2,712,741
identifier rows point at one of them.** Blocking requires a work
(`WHERE i.work_key IS NOT NULL` in `build_pool`), so those identifiers exist in
the artifact and can never produce a candidate. The effect on us is small — 318
books — but the two columns above measure different things and an earlier
version of this table conflated them.

## What that means for the matcher

**ISBN is the only identifier worth weighting heavily.** It sits on 84% of the
catalogue and finds an OL work for 86% of the books that carry one.

**Goodreads is the most widely held and the least useful of the two.** It is on
151,935 books — 96.3%, more than either ISBN — but reaches only a third of
them. Open Library does carry Goodreads ids (6,640,230 of them), so this is a
coverage gap on OL's side, not a missing code path. Treat a Goodreads hit as
good evidence and its absence as no evidence at all.

**ASIN is close to worthless as a blocking key at 12%.** Every ASIN we hold is
a Kindle `B…` code, and Open Library's 8.8M ASINs are overwhelmingly print. The
identifier is worth storing for other reasons; it is not worth weighting.

**The 24% no identifier reaches** is the population the `no_candidates` stratum
samples, and it is where the fingerprint rules have to carry the whole load.

## An ISBN hit is evidence, not proof

Labelling case `no_candidates-015` turned up the counterexample. Book #143219 is
Remini's *Andrew Jackson and the Course of American Empire, 1767-1821*, and its
ISBN `9780801859113` resolves in OL to `OL14865067W` — a work titled simply
**"Andrew Jackson"** carrying eight editions between 204 and 314 pages from
Twayne, Harper & Row, Meckler, HarperPerennial and Palgrave. At least three
different Remini books are conflated into that one work record, and the correct
work for our book (`OL14865056W`, 1977 Harper & Row, 502pp) is a separate
record OL holds three times over.

Our importer never captured that ISBN, so blocking produced nothing. Had it
captured it, the identifier rule would have fired and returned **the wrong
work**. The missing identifier accidentally prevented a false merge.

### And the identifier itself can belong to a different book

Book #138405 is von Baer's 1827 *De ovi mammalium et hominis genesi*, stored
under its English title. Its ISBN `9783442112975`, ISBN-10 `3442112974`, ASIN
and Goodreads id `1408396` all resolve to **`OL12708683M` — *Sag nicht Ja, wenn
Du Nein sagen willst*, Goldmann 1998**, a German self-help paperback. Every
identifier on the row belongs to a different book.

That edition happens to be one of the 1.9M with no work key, so blocking
produced nothing. Had it carried a work, the identifier rule would have matched
a 19th-century embryology treatise to a self-help paperback with full
confidence.

**This is now the third case where an unusable identifier prevented a wrong
match** — #143219's ISBN was never captured, DCeased's ASIN is absent from OL,
and this one is orphaned. The pattern is worth naming because it means our
current precision is partly luck, and improving identifier capture without
improving verification would spend that luck.

The `isbn_reuse` stratum (30 cases, one ISBN pointing at more than one work)
exists to measure how often this happens. Until it is labelled, do not treat an
identifier match as terminal.

## Regenerating

```bash
cd data-sources
uv run python - <<'PY'
import json
from openlibrary.pipeline.duck import connect
from openlibrary.pipeline.paths import ArtifactPaths
from pathlib import Path

p = ArtifactPaths(root=Path("/home/shane/ol-data"), dump_date="2026-07-31")
con = connect(p, memory_limit="12GB")
books = []
with open("/home/shane/ol-data/eval/books.jsonl", encoding="utf-8", newline="\n") as fh:
    for line in fh:
        if line.strip():
            books.append(json.loads(line))
rows = [
    (b["book_id"], typ, str(v))
    for b in books
    for field, typ in (("isbn13", "isbn13"), ("isbn10", "isbn10"),
                       ("asin", "asin"), ("goodreads_id", "goodreads"))
    for v in (b.get(field) or [])
]
con.execute("CREATE TABLE ours (book_id INTEGER, id_type VARCHAR, value VARCHAR)")
con.executemany("INSERT INTO ours VALUES (?,?,?)", rows)
for typ in ("isbn13", "isbn10", "asin", "goodreads"):
    nb = con.execute(f"SELECT count(DISTINCT book_id) FROM ours WHERE id_type='{typ}'").fetchone()[0]
    nv = con.execute(f"SELECT count(DISTINCT value) FROM ours WHERE id_type='{typ}'").fetchone()[0]
    hv, hb = con.execute(f"""SELECT count(DISTINCT o.value), count(DISTINCT o.book_id)
        FROM ours o JOIN '{p.table("identifiers")}' i
          ON i.id_type = o.id_type AND i.value = o.value
        WHERE o.id_type = '{typ}'""").fetchone()
    # The work_key filter is what makes this "usable", not merely "present":
    # blocking joins on it, so an identifier on a work-less edition is inert.
    (usable,) = con.execute(f"""SELECT count(DISTINCT o.book_id)
        FROM ours o JOIN '{p.table("identifiers")}' i
          ON i.id_type = o.id_type AND i.value = o.value
        WHERE o.id_type = '{typ}' AND i.work_key IS NOT NULL""").fetchone()
    print(f"{typ:<10} books={nb:>7,} vals={nv:>7,} inOL={hv:>7,} ({hv/nv:5.1%})"
          f" reaches_work={usable:>7,} ({usable/nb:5.1%}) orphan_only={hb - usable:>4,}")
PY
```

Note the `newline="\n"` on the open. `Path.read_text().splitlines()` also splits
on `\x85` and ` `, which some exported title contains, and that truncates a
record mid-JSON.

## Known limits

- **Coverage is not correctness.** Reaching a work means the value resolves,
  not that it resolves to the right work — or even to the right book. See the
  Remini and von Baer cases above.
- **Per-value and per-book coverage differ** because a book can hold several
  values of one type; both columns are given rather than one.
- **`asin` is measured as one type.** Some ASINs we hold are ISBN-10s rather
  than Kindle codes; those were not counted separately.
