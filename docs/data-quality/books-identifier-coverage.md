# Books: which identifiers actually reach Open Library

**Measured 2026-09-04** against the `2026-07-31` Open Library artifact and a
development database refreshed from production (157,805 exported books).

This is a matcher design input, not a repair list. It answers one question:
when the matcher has an identifier in hand, how often is that identifier
present in Open Library at all?

## Results

| Identifier | Books holding one | Distinct values | Present in OL | Value coverage | Books reached | Book coverage |
|---|---:|---:|---:|---:|---:|---:|
| `isbn10` | 136,650 | 214,747 | 173,393 | 80.7% | 118,071 | **86.4%** |
| `isbn13` | 133,057 | 166,736 | 138,947 | 83.3% | 113,660 | **85.4%** |
| `goodreads` | 151,935 | 193,915 | 58,352 | 30.1% | 50,844 | 33.5% |
| `asin` | 30,507 | 76,333 | 4,681 | 6.1% | 3,676 | **12.0%** |

**Books reachable by any identifier at all: 119,861 of 157,805 — 76.0%.**

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
    print(f"{typ:<10} books={nb:>7,} vals={nv:>7,} inOL={hv:>7,} ({hv/nv:5.1%}) reached={hb:>7,} ({hb/nb:5.1%})")
PY
```

Note the `newline="\n"` on the open. `Path.read_text().splitlines()` also splits
on `\x85` and ` `, which some exported title contains, and that truncates a
record mid-JSON.

## Known limits

- **Coverage is not correctness.** "Present in OL" means the value exists there,
  not that it points at the right work. See the Remini case above.
- **Per-value and per-book coverage differ** because a book can hold several
  values of one type; both columns are given rather than one.
- **`asin` is measured as one type.** Some ASINs we hold are ISBN-10s rather
  than Kindle codes; those were not counted separately.
