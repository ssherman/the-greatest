# Books: author disagreements against Open Library

**Measured 2026-09-04** against the `2026-07-31` Open Library artifact and a
development database refreshed from production (157,805 exported books).

**Regenerate this before acting on it.** The numbers below describe the
catalogue as it stood on 2026-09-04. The repair cannot happen until the new
site is live and the old one is off, and the migration will move these figures.
The script is the durable artifact; the snapshot beside it is a baseline to
compare against, not a work order.

```bash
cd data-sources
uv run python -m openlibrary.audit.authors \
  --root /home/shane/ol-data --dump-date 2026-07-31 \
  --books /home/shane/ol-data/eval/books.jsonl \
  --out ../docs/data-quality/books-author-suspects-<date>.jsonl
```

Runs in ~10 minutes, read-only, and touches nothing but the output file.

## What it does

The books domain's one external source is the Amazon Product API, which cannot
audit what is already stored. This is the first thing the distilled artifact
makes possible: join every local book carrying an ISBN, ASIN or Goodreads ID to
its Open Library work, then compare the author we hold against **every name OL
holds for that work's authors — alternate names as well as primary ones.**

That last point is load-bearing. `Kazuo Koike` is only an *alternate* of the
primary `小池一夫`; comparing primaries alone reports a disagreement where there
is none. The same applies to `John Lange`, a Michael Crichton pseudonym OL
records as an alternate.

## Results

118,309 books were comparable — we hold an author, and an identifier resolved
the book to an OL work.

| Class | Books | Share | What it means |
|---|---:|---:|---|
| `agrees` | 99,532 | 84.1% | a name matches exactly |
| **`surname_collision`** | **10,607** | **9.0%** | **shares a surname, rest differs — a different person** |
| `unrelated` | 2,764 | 2.3% | no tokens in common |
| `name_subset` | 4,009 | 3.4% | one name contains the other (initials) |
| `name_order` | 1,231 | 1.0% | same tokens, different order |
| `placeholder` | 166 | 0.1% | we stored `Unknown` / `Anonymous` |

A naive exact-fingerprint comparison reports **16.0% disagreement**. That figure
is wrong to act on: over a quarter of it is `Neville, Gary` against
`gary neville`. The classes below need four different kinds of work, and only
one of them is a data repair.

### `surname_collision` — 10,607 books, the actual problem

An author was matched on surname and an existing record for a different person
attached. Where that happened -- in our importer, or in the source data we
copied -- has not been established; see the attribution table in
`books-title-defects.md` for four rows traced by hand, which do not all point
the same way.

| Our author | Open Library's |
|---|---|
| Paul Auster | **Sara** Auster |
| Mahatma Gandhi | **Rajmohan** Gandhi |
| Ann Coulter | **Catherine** Coulter |
| S. A. Barnes | **Roy** Barnes |
| Herb Gold | **Kyell** Gold, **Sunny Sea** Gold |
| Taiyō Matsumoto | **Naoya** Matsumoto |

These cluster: author 13749 "Herb Gold" alone had five books, of which at least
two are provably other people. Repairing this means splitting buckets, not
correcting single rows, so the unit of work is the local author record rather
than the book.

### `unrelated` — 2,764 books, two different problems

Often not a wrong name at all. `Stephen Greenblatt` against Shakespeare — he
is the *editor*. `Josepha Sherman` against three contributors — an anthology.
`Paizo Staff` against individual designers. `Arvid Nelson` against
`robert castro` — a comics writer against the artist.

Our schema has `Books::Credit` for exactly these roles and it holds 19 rows in
total. Deciding what `book_authors` means for an anthology is a design decision
for the new importer, not a repair.

**But not all of them are modelling.** Some are Open Library errors. Book
#84336, the Polish edition of Aksel Sandemose's *En flyktning krysser sitt
spor*, is credited by OL to `Akshya Upanishad` (`OL9091340A`) — a record with
exactly one work to its name, while the correct author sits in OL twice over as
`OL10720715A` and `OL1520613A`. Our data is right and OL's is junk.

A single-work author record whose name shares nothing with ours is a usable
smell for this, and the proportion of the 2,764 that it accounts for has not
been measured. Until it is, do not read `unrelated` as "our data is fine but
modelled differently" — read it as "these need eyes".

### `name_subset` and `name_order` — 5,240 books, not corruption

`Irvin D. Yalom` / `irvin yalom`, `Mao` / `mao tse tung`, `Brian Davies` /
`davies brian`. Our data is fine; the *comparison* needs to normalise token
order and tolerate initials. That is the matcher's job, and these 5,240 pairs
are free test data for it.

## The snapshot

`books-author-suspects-2026-09-04.jsonl.gz` — the 13,371 `surname_collision`
and `unrelated` books, one JSON object per line:

```json
{"book_id": 76165, "title": "Sound Bath", "ours": ["Paul Auster"],
 "ol": ["sara auster", "jessica orkin"], "classification": "surname_collision"}
```

`ol` holds name *fingerprints*, not display names — that is what the comparison
runs on. Resolve a display name through `author_names` in the artifact when one
is needed for review.

## Known limits

- **Only books an identifier could resolve.** 118,309 of 157,805. A book with
  no ISBN, ASIN or Goodreads ID is invisible here; so is one whose identifiers
  are wrong, which is its own corruption class and would show as a confident
  match to the wrong book rather than as a disagreement.
- **Open Library is not ground truth.** It is a second opinion with its own
  errors, and labelling found four in the first 56 cases: `first_publish_date`
  22 years late on *Farlig midsommar*, 78 years late on *The Adventure of the
  Dying Detective*, a mislabelled volume number on *Pokémon 4*, and the junk
  author above. A disagreement means "these two sources differ", never "we are
  wrong".
- **`surname_collision` is not pure.** `Saveur Magazine` against
  `the editors of Saveur` lands there and is arguably the same entity.
- **Author-level clustering is not measured.** The counts are per book. The
  number of distinct *local author records* implicated is the figure a repair
  plan actually needs, and it is not computed yet.
