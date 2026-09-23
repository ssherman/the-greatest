# Books: what the save-time normalizer changes in the stored data

**Measured 2026-09-23** against the development database (a restore of
production: 158,220 books, 71,083 authors), with the `report` task below.
Regenerate before acting; the numbers describe a moment.

```bash
cd web-app
bin/rails books:normalize_names:report     # read-only
bin/rails books:normalize_names:apply      # rewrites the rows and flags collisions
```

## Why

Increment 1 of the import finder redesign chained `Services::Text::NameNormalizer`
(NFKC, every Unicode space separator folded to one space, runs collapsed, ends
stripped) after `QuoteNormalizer` in `Books::Book#normalize_title` and
`Books::Author#normalize_name`. Every save since then normalizes; rows written
before it were not. The finder's exact source compares the *normalized* query
against the *stored* value, so a stored `Kathleen Alcott` (U+202F) never equals
a query `Kathleen Alcott` until that row is saved once. `apply` saves those rows.

## What would change

| | Rows | Change | Whitespace only | NFKC beyond whitespace |
|---|---:|---:|---:|---:|
| `books_books.title` | 158,220 | 1,965 (1.2%) | 1,729 | 236 |
| `books_authors.name` | 71,083 | 3,436 (4.8%) | 3,403 | 33 |

(Each row is classified once: "whitespace only" means no NFKC change beyond
whitespace folding or a quote fold -- the classifier applies `QuoteNormalizer`
to both sides before comparing -- otherwise NFKC.)

Whitespace-only changes are runs of spaces (`House Of X   Powers Of X`), trailing
spaces (`Robin Morgan `), zero-width spaces (`Sheridan Keith​`, U+200B) and the
narrow no-break space (U+202F) that produced the 128 duplicate author groups in
`books-duplicate-rows.md`. Far more rows than the 365 that doc counted, because
it counted only exotic separators; a doubled ASCII space defeats the exact
source just the same.

NFKC changes beyond whitespace are, in order of frequency:

- **accent composition** (NFC, which NFKC includes): `Honorée` → `Honorée`,
  `Milanković` with a combining acute → precomposed. The visible string is
  identical; the bytes now match what a keyboard produces.
- **fullwidth to ASCII** in Japanese and Chinese titles: `Zoo〈１〉` → `Zoo〈1〉`,
  `北斗の拳（1）` → `北斗の拳(1)`, `藤子・Ｆ・不二雄` → `藤子・F・不二雄`.
- **compatibility characters**: `…` → `...`, `№7` → `No7`, `Nº 01` → `No 01`,
  `2ª Ed` → `2a Ed`, `E=Mc²` → `E=Mc2`, `ﷺ` → `صلى الله عليه وسلم`, `Ⅱ` → `II`.
  Lossy in the typographic sense, harmless for identity.
- **one regression, now fixed**: NFKC maps U+00B4 ACUTE ACCENT to a space plus a
  combining acute, so `Ardal O´Hanlon` became `Ardal O ́Hanlon`. Three rows (two
  titles, one author). `QuoteNormalizer` now folds U+00B4 to `'` first, so by the
  time NFKC runs there is nothing left for it to change beyond whitespace -- the
  report counts these three as whitespace only rather than NFKC, which is why its
  split differs from the pre-fix measurement by exactly these rows. The fold lives
  in `QuoteNormalizer`, which every domain's name and title normalizer calls, so a
  music, games or series row carrying U+00B4 is rewritten on its next save too --
  this measurement covers books only.

## What `apply` does

Saves each changed row through the model callbacks (so slugs are untouched —
FriendlyId only generates a slug when the slug column is nil, and both slug
columns are NOT NULL, so a rewrite never re-slugs — and the search index gets
a reindex request as on any save), normalizes `alternate_names` and
`alternate_titles` the same way, and raises a `bulk_verify` duplicate pair for
an author whose folded name (or a folded alternate name this run changed)
equals another author's, for a book whose folded title, or a folded alternate
title this run changed, equals another book's by an author of the same name,
and for a book whose authors were only made equal by an author rename. That last case is
checked without saving the book — a no-op save would still queue an index
request the book does not need. `pairs_flagged` is a count of distinct pairs,
not of flag calls. Nothing is merged; the pairs wait in the duplicates queue.

An author rename also queues one search-index request per book of that author
(`Books::Author` reindexes its books when its name changes), so expect tens of
thousands of index requests from the author pass alone — the bulk index queue
absorbs this fine.

A row the normalizer trims down to blank (an all-whitespace title or name)
fails presence validation; that row is reported in `errors` and left as-is
rather than aborting every other row's normalization.

Idempotent: a second run finds nothing to change.
