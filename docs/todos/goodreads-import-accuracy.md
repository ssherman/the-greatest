# Goodreads import accuracy

A starting point for a later brainstorming session, not a design. Written 2026-10-14, after the
first production Goodreads replay (`resolve`, then `duplicates`). Numbers come from the development
database, synced from production on the same day. Re-measure them before designing anything.

## Goal (Shane's words, 2026-10-14)

- Every Goodreads import is 100% accurate.
- Remove all the bad data the legacy Goodreads import feature left behind.
- Prevent the import from adding bad data in the future.
- Omnibus titles should never "split" into their individual books.

## Update later on 2026-10-14: the replay approach is in question

After the first `apply`, ten of the 58 rule-approved book merges turned out to be wrong. These are
verdicts 9744, 9758, 9760 and 9778–9781: distinct comic volumes ("X Men", "New X Men", "War Of
Kings") merged because they shared only an Open Library work id or an ASIN. Shane's conclusion:

> We can NOT trust any data from the Goodreads imports. Names and special characters were stripped,
> so books were matched or created with wrong names or wrong authors. Goodreads search then matched
> against wrong books and added the wrong identifiers to them; the Amazon product API matched the
> wrong books and added wrong ISBNs. We have the source of all the bad data. Why can't we go
> Goodreads import by Goodreads import and make sure every book is legit and 100% correct?

He asked for a **fresh brainstorming session** (`superpowers:brainstorming`) on this. It is
architectural. The replay repairs legacy's output pair by pair. The new idea rebuilds from the
source, the export rows.

**Paused until that session decides:** approving relinks or the AI's `strip_identifier` verdicts,
the books-only duplicate re-check, and any further `apply`. All of them were decided against the
tainted records.

**Already applied in production (2026-10-14), and staying:**
- 4,418 author merges, AI-checked and spot-checked;
- 46 book merges, 10 of them wrong (above). They are the X-Men-style lumps that the rebuild has to
  split back into volumes;
- 518 slug-form Goodreads id fixes;
- 24 authorless books flagged provisional.

Shane took a production backup just before that `apply`. A development restore of it is the
pre-apply state.

**Where the bad data came from**, in the legacy app at `~/dev/the-greatest-books/admin`:
- `app/lib/goodreads_library_parser.rb:96-98`: the search title drops everything in parentheses
  and everything after the first colon. So "X-Men: The Age of Apocalypse, Vol. 2" is searched as
  "X-Men", and series volumes collapse onto one bare title.
- `app/lib/book_finder.rb`, `app/lib/author_finder.rb`: the finders. Spec root cause 1: after the
  AI rejected every candidate, the finder re-ran the search and took the top hit anyway.
- `app/lib/openai/chats/goodreads_*_confirmation.rb`: the AI confirmations that were overridden.
- `app/lib/goodreads_cli.rb`, `app/lib/data_importers/books/goodreads_importer_from_url.rb`: the
  Goodreads lookups that stamped identifiers.
- `app/lib/data_importers/editions/sources/amazon.rb`, `app/lib/openai/chats/amazon_match_confirmation.rb`:
  Amazon matching, the source of the wrong ISBNs.
- Spec §1, "Legacy root causes, ranked", already lists more of them.

**The working understanding** at the end of the session, not yet confirmed by Shane:
- The trustworthy source is the export itself. Each row holds Goodreads' own Book Id, exact title,
  author and ISBNs; legacy stripped them only afterwards. The Goodreads page adds the original
  title, series and author roles.
- Everything downstream of legacy's choice is suspect: which book it picked, the titles and authors
  on books it created, every identifier it stamped, and whatever Goodreads search and Amazon
  enrichment added later.
- "Correct" means three things: every user's list item and review points at the book they had on
  Goodreads; every import-touched book has the right title and authors; every identifier on a book
  belongs to it.
- The scale is 803 imports, 498,570 rows and 208,441 distinct Goodreads books. About 135k of 160k
  books were created by imports. It has to be automated per Goodreads book, with human review of
  the exceptions only.
- Only 39,358 Goodreads pages are cached (legacy scrapes, no HTML). Fetching the rest is a long
  page-fetcher job, so lean on the export rows and fetch only when they do not settle it.
- The weekly legacy sync is a constraint. Until the switch-over it restores legacy users' items and
  reviews as legacy has them, so whatever is built must re-apply after every sync. That is why the
  replay records verdicts keyed by preserved ids.

**The first open question:** can a book legacy's imports created be thrown away and replaced? That
means building the correct book from the export rows, moving users onto it and deleting legacy's
record. The alternative is to correct each legacy record in place: fix the title and authors, strip
identifiers, and split lumps. Replacing is simpler and more reliable, but legacy book ids, and any
URLs already indexed for them, go away.

## The original plan, before the update

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
