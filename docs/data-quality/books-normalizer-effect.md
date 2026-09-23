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

(Each row is classified once: NFKC if the full normalizer changes more than
whitespace folding alone would, otherwise whitespace only.)

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
  combining acute, so `Ardal O´Hanlon` became `Ardal O ́Hanlon`. Two rows.
  `QuoteNormalizer` now folds U+00B4 to `'` first.

## What `apply` does

Saves each changed row through the model callbacks (so slugs are untouched —
FriendlyId only generates a slug when it is blank — and the search index gets a
reindex request as on any save), normalizes `alternate_names` and
`alternate_titles` the same way, and raises a `bulk_verify` duplicate pair for an
author whose folded name equals another author's and for a book whose folded
title equals another book's by an author of the same name. Nothing is merged; the
pairs wait in the duplicates queue.

Idempotent: a second run finds nothing to change.
