# Goodreads import accuracy

A starting point for a later brainstorming session, not a design. Written 2026-10-14, after the
first production Goodreads replay (`resolve`, then `duplicates`). Numbers come from the development
database, synced from production on the same day. Re-measure them before designing anything.

## Goal (Shane's words, 2026-10-14)

- Every Goodreads import is 100% accurate.
- Remove all the bad data the legacy Goodreads import feature left behind.
- Prevent the import from adding bad data in the future.
- Omnibus titles should never "split" into their individual books.

**Not now.** Correcting the issues the replay already found and clearing duplicates comes
first: approve the verdicts, then `apply`, then the books-only duplicate re-check. This file is
the next project after that.

## The main gap: unmatched rows keep the wrong book

The replay compares legacy's book for each row with the book the new matcher finds. When the
matcher finds nothing (`replay_finding: unmatched`), it records **no verdict**, and the replay
never creates books (spec §12.3). So the user's list keeps whatever legacy put there.

11,811 unmatched rows (6,372 distinct Goodreads books). Every one of them has a legacy book on the
user's lists. Split by the row's title against the title of legacy's book (trailing parenthesised
series stripped):

| Title vs legacy's book | Rows | Distinct Goodreads books | Reading |
|---|---|---|---|
| Completely different | 3,581 | 1,782 | Wrong book on the list, across 456 imports |
| One contains the other | 6,161 | 3,316 | Mixed: omnibus collapses and harmless subtitle or series differences |
| Same title | 2,069 | 1,280 | Legacy probably right; the matcher could not corroborate it |

Examples of completely different titles: "Does a Kangaroo Have a Mother, Too?" is on the list as
*The Mask of Dimitrios*, "The Tiny Seed" as *The Order of the Day*, "Paddington Bear at the
Circus" as *Gloriana*.

**Worked example: the omnibus collapse** (legacy import 683, user 69027). The user had four
Selma Lagerlöf books on Goodreads: the omnibus *Herr Arnes penningar / Liljecronas hem /
Körkarlen* (row 119, 450 pages) and the three novellas (rows 967, 909, 983). Legacy put **all
four** on the omnibus record, book 140235, and stamped each row's Goodreads id and ISBNs onto it.
The replay agrees on row 119 and relinks row 967 to *The Treasure* (22252, verdict 5111). It
leaves 909 and 983 unmatched, so they stay on the omnibus. The novellas' identifiers also stay on
the omnibus record, where a future import of those ISBNs would match the omnibus.

A fix has two parts:
1. Create the missing book through the member import's creation path (Goodreads page check,
   provisional book and authors).
2. Record a relink from legacy's book to it. The existing relink already copies instead of moving
   when another row still needs the old book.

Open question raised but not decided: create books only for rows that legacy's book clearly
contradicts (title and author disagree), or for every unmatched row. Every unmatched row would be
about 6,400 books, many duplicating a legacy book that was already right.

## Other gaps the replay leaves

- **Rows legacy never placed** (`no_legacy_choice`): 51,837 rows. 30,391 are in imports the
  replay marks failed, which `finish_legacy` largely covers on the final pass. 21,446 are in
  completed imports. Those could be rows legacy skipped, or books the user later removed from a
  list, and the data does not tell them apart.
- **Identifiers legacy stamped on the wrong book.** A relink moves the row's identifiers only when
  legacy's book contradicts the row on title and author. A containing title, such as an omnibus
  holding a novella's title, does not count as contradicting, so the novella's ISBN stays put.
- **Duplicate pairs the rule cannot merge.** About 4,100 pending book pairs stay in the queue after
  the replay. Most are translations ("Milkman" and "Melkboer"), which the equal-title rule never
  merges by design. A bulk path for AI-flagged pairs with identical authors would save merging
  them one at a time.
- **Accented author names never group.** The author duplicate key strips punctuation but keeps
  accents, so "Carlos Ruiz Zafon" and "Carlos Ruiz Zafón" never reach the AI check.
- **`books:goodreads_replay:duplicates` is one silent rake run.** About 3,188 AI calls run one after
  another, for hours, and it prints only at the end. It should queue Sidekiq jobs and report counts
  like `resolve` does. It runs on every replay pass.

## Preventing bad data from new imports

Member uploads already avoid legacy's worst habits: every created book is provisional until an
admin approves the import, and a row Goodreads proves fake is parked rather than created. To
check when designing this:
- Can a member import still collapse several Goodreads rows onto one book, as legacy did with the
  omnibus?
- Can it still stamp a row's identifiers onto a book whose title and author do not match the row?
- The open member-import items under "Goodreads import: before the cutover" in `docs/todo.md`.

## Where things are

- Spec: `docs/superpowers/specs/2026-10-03-goodreads-import-design.md` (§12 is the replay).
- Feature doc: `docs/features/goodreads-import.md`, "Legacy replay".
- Replay code: `web-app/app/lib/services/books/goodreads_replay/`.
- Rows: `Books::GoodreadsImportRow` (`replay_finding`, `legacy_book_id`, `raw`).
