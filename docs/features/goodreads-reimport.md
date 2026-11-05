# Goodreads re-import

Matches every legacy Goodreads CSV row to the exact book it names, from scratch, and moves each reader's
entries there. It replaces stage two of the rebuild (`docs/features/goodreads-rebuild.md`). Design and the
reasons: `docs/superpowers/specs/2026-11-02-goodreads-reimport-design.md`. Production steps:
`docs/launch-todo.md` section 12.

Legacy's importer cut titles at the first colon and guessed authors, so readers sit on the wrong books. This
run ignores legacy's choices (its identifiers never count as evidence) and treats each row as if it had just
been uploaded.

## The gate

Two switches, both off by default, both read from ENV on the server that runs Sidekiq
(`config/initializers/goodreads_reimport.rb`, `config.x.goodreads_reimport`):

- `GOODREADS_REIMPORT_ENABLED` turns the run on. While it is off, the archive, match, decide, apply and
  author-check jobs return without writing, and their rake tasks abort with a message.
- `GOODREADS_REIMPORT_ENRICHMENT` separately allows enrichment of the books the run creates. Keep it off until
  the new enrichment steps (categories, origin) have landed.

The report, snapshot and sample are read-only, so they work with the gate off.

## How it runs

Every step is a Sidekiq job. The rake task only queues it (or prints). Each job can be stopped and run again
safely: it carries on from what is not done yet. Tasks live in `lib/tasks/books/goodreads_reimport.rake`, jobs
in `app/sidekiq/books/goodreads_reimport/`, logic in `app/lib/services/books/goodreads_reimport/`.

| Step | Task | What it does |
|---|---|---|
| Archive | `archive_mixed` | Records, for each mixed book, everything on it. Deletes nothing. |
| Match | `match[<count>\|all]` | Finds the book for each Goodreads edition. An AI check looks at every match. |
| Apply | `apply` | Carries out approved verdicts, one apply run at a time; each run picks up where the last stopped. |
| Decide | `decide[<count>\|all]` | Per user: keep, move, copy or add each row. Also queues guesses for mixed books. |
| Snapshot | `snapshot[redo]` | Saves each affected user's list-item and review counts before the first apply that moves rows. |
| Author check | `check_authors[<count>\|all]` | Checks each import-made book's credited authors against its rows. |
| Report | `report` | Writes the report file. |
| Sample | `sample` | An independent AI check of random rows. |

All tasks are `books:goodreads_reimport:<name>`.

### Mixed books

A mixed book is an import-made record whose readers came from several different books (1,654 in the
survey). They come from the fresh survey's lump classification, so refresh the survey first
(`books:goodreads_rebuild:survey[all,redo]`). Archiving writes an `reimport_mixed` verdict with a copy of
everything on the record, including each image's columns and its stored file's identity (blob id, key, checksum).
The record stays matchable (change 2026-11-03: the survey's mixed rule groups by author and year and ignores
titles, so many "mixed" records are the right English book, and the per-edition AI check decides). The record is
deleted later, once every row on it has moved. Deleting detaches each image's file first, so the stored file is
kept and the archive can re-attach it.

If any reader is headed to the mixed record, `decide` marks the verdict `kept`. "Headed to" is read from the
database, not from the record's own rows: any current, non-rejected, non-superseded `reimport_row` verdict (of any
reader, from any book) whose destination is the record, or any current, non-rejected `reimport_match` that matched an
edition to it. A kept record gets no guesses, its earlier unapplied guesses are superseded, there is no redirect, and
`apply` closes it with "kept: readers matched this book" without deleting anything. `apply` re-checks the same
condition under the book's lock, so a delete never races a new match. If nothing heads there any more, the next
`decide` flips it back and reopens it. When a kept record closes, `apply` also removes the copy originals of users whose
rows were copied away from it (recorded in the verdict's `deleted`), except the items a row heading to the record
accounts for, so the record holds exactly what its readers' rows say; it waits while such a copy is unapplied. Guesses already applied before the record turned out to be kept are not
undone; the report lists them for hand review. When a record is deleted, `apply` writes every image's columns and its
stored file's identity into the verdict (`deleted_images`), covering images added after the archive.

Entries a user added by hand to a mixed book (not from a CSV row) cannot be matched. They go to the record's
most-read book and are marked as guesses (`reimport_guess`). `decide` queues these, but a book whose rows are
not all decided yet answers "waiting", so run `decide[all]` a second time after the first pass has finished.

## The verdict kinds (the audit record)

Everything is written to `books_repair_verdicts` before it happens. Admin, Repair verdicts shows them.

- `reimport_mixed`: a mixed book, archived and later deleted.
- `reimport_match`: one Goodreads edition matched to a book.
- `reimport_row`: one CSV row, with an action: keep (already right), move, copy (legacy put two editions on one
  book) or add (the row had no entry). A new book is made by a `reimport_match` with outcome create, not a row action.
- `reimport_guess`: a hand-added entry from a mixed book, moved to its most-read book.
- `reimport_strip`: a legacy identifier removed from a book. Applying a match records one for every OTHER book that
  holds the edition's own Goodreads id, ISBN-13 or ISBN-10 (from the CSV) as a legacy-sourced identifier; apply removes
  only legacy-sourced ones.
- `reimport_author`: a correction to a book's credited authors.

A status says what happens next: approved ones are carried out by `apply`; proposed ones wait for Shane;
rejected ones are never carried out.

## Reviewing proposed matches

The AI always sees the book the reader is on today as one of its choices, even when the finder missed it (a
translated title finds nothing in an English catalog). When the AI confirms the finder's match with high
confidence, it is approved by itself; so is the reader's current book when the finder found nothing and that
book is not a mixed book, and a new book when the AI says "none of these" with high confidence. When they
disagree or the AI doubts it, the match is proposed. Review them in Admin, Repair verdicts, filtered to `reimport_match`:

- Approve a match that is right; `apply` then writes it.
- Reject one that is wrong. A rejected match stays rejected and its rows **wait**: they are not moved, and the
  report lists them under "rejected matches". Fix the cause (or leave them for a later pass) and they stay put.
  Rows the same reader had on the same legacy book wait with them (a row with no edition does the same), because
  copy versus move and the review's owner depend on every row of that book: nothing of the group moves until
  all of it can.

The report's "AI agreement" line shows how many matches were approved without anyone looking. A low rate means
the AI and the finder disagree a lot and most of the review falls to Shane.

## The report

`books:goodreads_reimport:report` queues a job. It writes
`storage/goodreads_reimport/report-<UTC time>.md` (for example `report-20261105T140000Z.md`), a plain-text file,
and logs the path in the Sidekiq log. The worker writes it into the shared storage volume, which is mounted in both web and worker, so you can
read it from either container and it survives a deploy. It lists:

- counts per kind and status, and per row action;
- proposed verdicts waiting for Shane;
- mixed books stuck waiting (rows not yet decided), rejected matches, and verdicts closed because there was nothing left to do
  (nothing left to do, each with its reason);
- verdicts with an error;
- a random sample of each kind;
- the acceptance queries, each of which should print 0:
  - rows whose book's title differs from the CSV title with no approved verdict explaining it;
  - users whose list-item or review count dropped, beyond the destroys the verdicts recorded (a destroy from
    a collision is listed separately as explained);
  - mixed books still present (kept ones are counted on their own line and are not a failure).

If a deploy interrupts the job, run the task again. The snapshot (`counts.json` in the same folder) is what
the "count dropped" query compares against. Take it before the first apply that moves rows. `snapshot` leaves an existing
snapshot alone; `snapshot[redo]` replaces it, which you should only do before any apply that moves rows, because a snapshot
taken afterwards would hide every loss.

## The sample check

`books:goodreads_reimport:sample` queues a job that asks an AI reviewer, independent of the matcher's
verdicts, whether each sampled row's final book is the work the CSV row names. It checks 300 random applied
rows plus the rows of 20 former mixed books. It writes **no file**: the result is in the Sidekiq log, on the
line "Goodreads re-import sample check:". It prints how many rows were answered no (each listed) and how many
could not be checked. It makes hundreds of AI calls, so it takes a while. If a deploy interrupted it, enqueue it
again; nothing is saved part-way.

**Any "no" stops the run** until its cause is fixed (spec section 6).

## The weekly legacy sync

`data_migration:sync` rewrites legacy users' lists to match legacy and routes deleted books' items through
`record_redirects`. As it stands it would undo moved rows and send a deleted mixed book's readers to one book.
Do not run it until it has been checked and changed so it cannot revert this run (spec section 3.9).
