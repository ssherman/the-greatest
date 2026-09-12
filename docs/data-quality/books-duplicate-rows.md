# Books: rows we hold twice, found through Open Library

**Measured 2026-09-05** against the `2026-07-31` Open Library artifact and a
development database refreshed from production (157,805 exported books).

```bash
cd data-sources
uv run python -m openlibrary.audit.duplicates \
  --root /home/shane/ol-data --dump-date 2026-07-31 \
  --books /home/shane/ol-data/eval/books.jsonl \
  --out ../docs/data-quality/books-duplicate-candidates-<date>.jsonl
gzip ../docs/data-quality/books-duplicate-candidates-<date>.jsonl
```

Read-only, ~4 minutes. `books-duplicate-candidates-2026-09-05.jsonl.gz` is the
1,042 groups, one JSON object per line with each row's title, authors and year.

## Why not compare titles

`books-title-defects.md` finds duplicates by grouping on (author, title). That
misses the largest class entirely, because the two rows do not share a title:

```
#14079   The Great Crash, 1929        1955   John Kenneth Galbraith
#168338  Der Grosse Crash 1929        1955   John Kenneth Galbraith
```

`Books::Book` is work-level, so resolving each row's identifiers to an Open
Library work and asking which works more than one row claims finds these
without looking at the title at all.

## Results

| | Works | Books |
|---|---:|---:|
| resolved to any OL work | — | 119,550 |
| OL works claimed by more than one of our rows | 4,050 | 7,635 |
| **confident — each row's only claim is that work** | **1,042** | **2,209** |

Group sizes in the confident set: 956 pairs, 64 threes, 17 fours, 2 fives, and
one each of seven, nine and eleven.

**Use the 1,042, not the 4,050.** A row that resolves to several works shares
one of them nearly for free — book #14079 resolves to four, because Open
Library holds *The Great Crash, 1929* nine times over — and an overlap that
cheap is not evidence.

## Three mechanisms

| | Groups |
|---|---:|
| different titles — translation or spelling variant | 808 |
| an exotic space in an author name | 128 |
| identical titles | 106 |

**Translations held as separate rows** are the bulk. *Southern Seas* beside
*Os Mares Do Sul*; *The Jakarta Method* beside *El Método Yakarta*; *Just After
Sunset* beside *Po Zachodzie Słońca*.

**Spelling variants** are the same book under two renderings: *The Secret Lives
Of Colour* and *The Secret Lives Of Color*.

**Exotic whitespace in an author name** is the one with a code fix. `Kathleen
Alcott` and `Kathleen Alcott` — a U+202F narrow no-break space — became two
Author records and then two Books. **365 books carry an exotic space in an
author name** (354 of them narrow no-break), and 71 carry one in the title.

That is *not* a matching bug: `common.normalize.name_fingerprint` already folds
U+202F to a space, so both forms fingerprint to `kathleen alcott`. It is the
Rails importer doing an exact-string author lookup. Normalising whitespace
before that lookup stops new ones appearing; it does not repair the 128 already
here.

## Two limits, and both matter

**This is a floor.** A row Open Library cannot place is invisible. The German
Galbraith that prompted the whole measurement has no ISBN in OL, so the pair
`(14079, 168338)` — a duplicate we know for certain is real — **is not in the
1,042**. The true number is higher and this method cannot say by how much.

**It is also not a verdict.** Open Library conflates works of its own, and a
conflation looks exactly like a duplicate from here:

- `OL16825084W` holds *Four*, *The Traitor* and *The Transfer* — three
  different Veronica Roth novellas. Three of our rows land on it.
- `OL76341W` pairs *The Innocence of Father Brown* with *The Annotated
  Innocence Of Father Brown*, which are arguably different books.

The output is a review queue for the record-merge tooling, not a merge script.

## Wrong-author rows show up here too

Grouping by work surfaces the `surname_collision` class of
`books-author-disagreements.md` by a completely independent route:

- `OL31142862W` — *The Lookback Window* under **Noreena Hertz** and under
  **Kyle Dillon Hertz**. It is Kyle Dillon Hertz's book.
- `OL34080440W` — *Wrong Way* under **Joanne McNeil** and **Legs McNeil**. It
  is Joanne McNeil's.

Two rows, same work, different surnames-in-common authors: one of them is
wrong, and which one is decidable from Open Library's author names.

## The import-time version is the one that scales

Nothing here repairs anything, and running it after the fact will always trail
the data. The same resolution done **at import** — resolve the incoming book to
an Open Library work, then check whether we already hold a book on that work,
and merge rather than insert — catches the pairs this method cannot see,
because it only needs the *incoming* row to resolve. The German Galbraith would
have been caught that way and was not caught this way.
