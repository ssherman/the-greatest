# Unsure books: a second chance in stage 1

Design, 2026-10-21. Extends the book verification pass (`docs/superpowers/specs/2026-10-16-book-verification-design.md`,
feature doc `docs/features/book-verification.md`). Approved in conversation with Shane on 2026-10-21
after a read-only investigation on a fresh production restore.

## Why

The production pass over the 12,143 ranked books created before the Goodreads import finished on
2026-10-21. 4,011 of them (33%) came back `unsure`: stage 1 could not settle an Open Library work, so
they get no Open Library identifiers at all (stage 2 is skipped) and only WorldCat confirmations of
ISBNs they already held. The rate rose further down the ranking.

These books matter for the next project. The Goodreads rebuild (`docs/todos/goodreads-import-accuracy.md`)
will match Goodreads export rows to catalog books on verified identifiers only. Unsure books carry
21,551 Goodreads export rows (settled books carry 127,777), and they are disproportionately famous:
*One Hundred Years of Solitude* (372 rows), *The Metamorphosis* (328), *Frankenstein* (321),
*The Trial* (276), *The Count of Monte Cristo* (263), *The Iliad* (238). Shane's call: fix this before the
rebuild.

## What the investigation found

All 4,011 went through Open Library's `/resolve` (matcher v3, dump 2026-09-30) and none was accepted
and verified. 3,618 still hold a legacy Open Library key. Two read-only probes on dev (scripts and
JSON in the 2026-10-21 session scratchpad; re-run them before relying on the numbers):

1. **`/resolve` re-asked for 50 books** (the top 25 by Goodreads rows, 25 random):
   - **The matcher declined, but a candidate passes our title-and-author check.** *One Hundred Years
     of Solitude* (top candidate is the English work, score 0.882, between the thresholds), *A Christmas
     Carol* (margin 0.191 against 0.204), *Frankenstein*, *Perfume*, *The Aeneid*, *Homo Deus*,
     *In Search of Lost Time*, *Java Head*, *Dianetics*. In *The Iliad* the top candidate is the Greek
     *Odyssey* (fails our check) and the Greek *Iliad* is second (passes): the rule cannot be "take the
     top candidate".
   - **The matcher accepted, but our check rejected it on formatting.** "The Metamorphosis" vs
     "Metamorphosis" (leading article), "Atlas Shrugged (Centennial Ed. HC)" (trailing parenthetical),
     "Surely You're Joking, Mr. Feynman" (quotes). The same comparison also fails "From Russia, with
     love", "Ashenden or the British Agent" vs "Ashenden, Or, The British Agent" (commas), "L' huile sur
     le feu" (apostrophe spacing) and "Mariage de Figaro" vs "Le Mariage De Figaro" (French article).
   - **The right work is there but scored low.** Open Library ranks the original-language work highest
     because it holds most editions. For *The Trial*, *Demons*, *We*, *The Opium of the Intellectuals*
     and *A History of the Crusades*, a work with our exact title and author sits in the reject band.
   - Estimated: about 21 of the top 25 and 13 of the 25 random would settle under the rules below.
     The rest are correctly unsure (*Lumumba Speaks* and *Encyclopédie* are not in Open Library;
     *Gloriana* is a legacy lump of wrong Goodreads rows; *Persepolis* and *Monte Cristo* offer only
     omnibus or volume works).
2. **Held keys and WorldCat ISBNs, 195 books** (top 25 plus 170 random; 5 timed out):
   - 67 (34%) hold a legacy key that passes our check today. Stage 1 did not confirm it only because
     `/resolve`'s top candidate was another work.
   - 54 hold WorldCat-confirmed ISBNs that lead (Open Library `/identifiers`) to a work that passes.
   - 84 (43%) settle by one or the other, before any formatting fix. In the 9 books where the two
     routes disagree, both point at the same book (duplicates, translations, volumes): no contradiction.

## Goals

- Settle as many unsure books as possible **without ever settling one on the wrong work**. A book left
  unsure costs recall; a wrong key costs trust, and stage 2 then stamps that work's ISBNs as trusted.
- Every new route still ends in our title-and-author check. Nothing is accepted on score alone.
- Re-run the 4,011 existing unsure rows once; new books and future runs get the same rules.
- Record which rule settled each book, so the report can sample each rule for a hand check.

## Non-goals

- No change to the Open Library service or its matcher (`data-sources/`).
- Books already settled are not redone. The new comparison applies to them on their next normal run.
- The post-import cohort stays held back until the Goodreads rebuild (unchanged).
- Choosing a better work for books settled on a translation's work (*Cuckoo's Nest*, *Pillow Book*).
  This design can make that happen more often (see "Known costs"); fixing it is a later spec.
- The `wrong_identifier` signal's other false positives (CJK parallel titles). Only what the new
  comparison fixes in passing.

## Anti-goals

- A wrong book becoming settled. If the rehearsal's hand check finds one, the rule that produced it is
  tightened or dropped before production. Precision beats recall here, as it did for the whole pass.
- A volume or omnibus settling as the whole book ("In Search of Lost Time (In Search of Lost Time 1)",
  "History of the Crusades III", "Le Comte de Monte-Cristo, II", "Persepolis 1-4"), or the reverse.

## The design

### 1. A forgiving title comparison (shared by every check)

`Check` compares titles by exact normalized equality, with one-sided subtitle dropping. Add a
**comparison key** used wherever two titles are compared for agreement (`Check.titles_agree?`, the
title rules in `EditionCheck`, `WorldCatCheck`, `Signals`, and the duplicate-work gate in
`HarvestEditions#same_title?`). The key is never stored. Starting from today's `Check.normalize`:

- diacritics folded (NFKD, combining marks removed), plus the letters NFKD does not decompose:
  ø→o, æ→ae, œ→oe, ß→ss, đ→d, ł→l, þ→th;
- every character that is not a letter, digit or space becomes a space (commas, quotes, hyphens,
  apostrophes, periods, "&"); spaces collapse;
- one leading article dropped: English (the, a, an), French (le, la, les, l'), Spanish (el, la, los,
  las), Italian (il, lo, la, i, gli, le, l'), German (der, die, das), Portuguese (o, a, os, as);
- a **trailing parenthetical** counts as a subtitle: it may be dropped from one side under the existing
  one-side rule, **unless** it names a volume, part or set: it contains a digit, "#", or a whole word
  vol, vols, volume, volumes, book, books, part, tome, or matches `EditionCheck::SET_WORDS`.
  This also blocks Goodreads-style series markers ("Mort (Discworld, #4)"). That is deliberate: it
  costs only recall.

Order matters and is the builder's to get right: split the subtitle (":" and the trailing
parenthetical) **before** the punctuation is removed, then key each part. The existing one-side
subtitle rule, the `SET_WORDS` guard on a dropped edition subtitle, and the year rule are unchanged.

The same letter folding goes into `Check.compact` (author comparison), so "Søren Kierkegaard" agrees
with "Soren Kierkegaard".

The author rule is unchanged: every route below still needs an author to agree.

### 2. When `/resolve` does not settle the book: its best passing candidate

Today, a non-accept settles only when the top candidate is a key the book already holds
(`Lookup#confirmable_stored_key`). Replace that with:

1. Take the resolution's candidates whose own verdict is not `reject`, in the order the service
   returned them (score order). **The matcher's guards still hold** (my call, from the anti-goals): no
   second chance at all when the decision abstained because of an identifier conflict ("identifier
   conflict on the best candidate") or a refused search (`volume_guards_tripped` is not empty), and a
   candidate with any `conflicting_features` is never taken. Only abstains on score or margin, and
   accepts our check rejected, get the second chance.
2. Settle on the first that passes `Check.verified?`, preferring one whose title key equals the key of
   `book.title` or of an alternate title over one that passes only by dropping a subtitle.
3. Every other candidate in the response that also passes `Check.verified?` is saved as a duplicate
   work key (`books_work_openlibrary_duplicate_id`, through `ApplyBook#save_duplicates`), so stage 2's
   strict duplicate gate decides whether its editions are harvested.

This also covers an `accept` whose accepted work fails our check: fall through to the same list.

### 3. Otherwise: a reject-band candidate with our exact title

If step 2 found nothing, take the highest-scoring candidate in the reject band whose title key equals
the key of `book.title` (not an alternate title, not by dropping a subtitle) and whose author agrees
(`Check.verified?`'s author half, with the author-record fetch). This is the *Trial* / *Demons* / *We*
case: an English-titled work that Open Library ranks below the original-language work. The same guards
as step 2 apply: no step 3 after an identifier-conflict or refused-search abstain, and never a
candidate with `conflicting_features`.

### 4. Otherwise: the legacy key the book already holds

If the book holds a `books_work_openlibrary_id` (legacy) whose live work passes `Check.verified?`,
settle on it. With several, prefer an exact title key, then the oldest identifier. A held key whose
record is clearly another book is still removed, as today.

### 5. Otherwise: the WorldCat-confirmed ISBNs

Look up at most 5 of the book's ISBNs whose source is `worldcat` in Open Library (`/identifiers`,
same concurrency and error handling as the fast pass). Group the hits by work, most hits first. Settle
on the first work that passes `Check.verified?`; other passing works become duplicate keys. This needs
stage 3 to have run once, which is true for every existing unsure row; a brand-new book reaches this
step with no WorldCat ISBNs and skips it.

### 6. Otherwise: unsure, as today

### What a second-chance settle changes (my call)

The routes are weaker evidence than a matcher accept, so a wrong pick must stay on the book:

- The book is settled like an accept: its work key is set (source `open_library`), duplicates are
  saved, and its other held work keys go the way they do for `replaced` today (kept as duplicate keys
  when their own record passes our check, removed otherwise). The existing guard stays: a key another
  book already holds makes this book a `duplicate_pair` that takes nothing.
- **No Open Library author keys are written** (`AuthorKeys` is skipped). Author keys come only from a
  matcher accept, as today, so a wrong pick cannot spread to author records.
- Duplicate pairs are still flagged for review; that is a recorded signal, not a write.

### Which rows get the second chance (my call)

The 4,011 `unsure` rows and the 126 `removed` rows. Both had no confident answer and hold no settled
key. A `removed` row's `old_keys` (the key it removed, which revert restores) must survive the re-run:
merge, never overwrite. Today `ApplyBook::REPROCESSABLE` excludes `removed`; the re-run flag takes it
explicitly.

### Revert (my call)

`books:verify_revert[<book id>]` must undo a second-chance settle, and a bulk form must revert every
book settled by one route (for example `books:verify_revert_route[<lookup value>]`), because the
production spot-check is per route. A reverted second-chance book goes back to what it was before the
second chance: `unsure` (or `removed`), with its first pass's work keys, WorldCat confirmations and
findings intact, and eligible for a later run. Only what the second chance and its stages 2-4 wrote is
undone. The builder decides how to tell those writes apart (the run id, timestamps, or a marker).

### Recording and outcomes

- Outcomes stay the existing ones (`confirmed` when the settled key was already held, `keyed`,
  `updated`, `replaced`). A settled book continues to stages 2-4 as any settled book does.
- Record which route settled it, for the report and for revert: extend `Books::Verification#lookup`
  (today `identifiers` / `resolve`) with one value per new route (the builder names them, for example
  `resolve_candidate`, `exact_title`, `held_key`, `worldcat_isbns`). This is an integer enum, so it is
  a code change, not a migration.

### Re-running the existing unsure rows

A new `Run` flag that takes every `done` row whose `work_outcome` is `unsure` or `removed` and starts
it over at stage 1, once per run, like `reharvest`: a book the same run already finished is not taken again, so a
re-queued run does not redo it; a later run with the flag redoes them all again (idempotent, costs only
time). It respects the default scope (ranked, `pre_import`) and `unranked` / `post_import` like the
other flags. Name it in the builder's plan; `retry_unsure` keeps its meaning (older dump or matcher).

Cost: one `/resolve` per book (12-13 s, serial in the service) plus stages 2-4 for each book that
settles. Roughly a day for 4,011.

### Report

`books:verify_report` gains, per route: how many books it settled, and 10 random samples showing our
title and authors against the settled work's title and authors (the existing sample format).

## Proving it

1. **Unit tests** for every rule, including each named case above as a fixture-level test: the
   formatting cases agree; volume parentheticals do not; *Iliad* settles on the second candidate, not
   the first; *Demons* settles on the exact-title reject-band work; a reject-band work whose title
   only matches an alternate title does not.
2. **Dev rehearsal on all 4,011 unsure rows** (dev holds them: a production restore from 2026-10-21).
   Snapshot dev first. Hand-check at least 30 settled books per route, all of the top 100 by Goodreads
   rows, and every book whose settled work's title differs from ours. Success: **no wrong work** in
   the hand check. A wrong pick tightens or drops its route before production.
3. **Production:** deploy, run the flag over the unsure rows, then the report and the same spot-check
   used for the earlier runs.

## Known costs

- **Translation works.** Steps 2 and 4 can settle a book on a translation's or the original's work
  (*Notes from Underground* on a German work, *Death in Venice* on an Italian one): the right book, but
  most English editions may sit under another work. Stage 2 then harvests that work's editions, and
  its duplicates only if they pass the strict gate. Accepted for now (non-goal above).
- **The comparison change reaches settled books' later runs.** Agreement gets more forgiving
  everywhere, including which editions stage 2 trusts. The guards that matter stay: an author must
  agree, a dropped edition subtitle or parenthetical may not name a set or volume, and the duplicate
  gate still needs our own full title.
- **Same title, same author, different work.** Two different works by one author with the same title
  (two "Selected Poems") cannot be told apart by title and author. Step 3 and the duplicate saves make
  this slightly more likely to surface. The hand check looks for it.

## Left to the builder

- Names: the `lookup` values, the `Run` flag, any new classes. Whether the routes live in `Lookup` or
  a new collaborator.
- How many reject-band candidates `/resolve` returns is the service's; use what comes back.
- The exact place the comparison key lives (`Check` is the natural home).
- Test fixtures and how the rehearsal script samples.
