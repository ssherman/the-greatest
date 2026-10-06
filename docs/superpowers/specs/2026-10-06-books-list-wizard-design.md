# Books list wizard and the shared wizard core

Spec 2 of 3 for the books list importer. Spec 1 (OL matcher v3, PR #354) made Open Library
decide on list-style queries. The local-holders fix (PR #356) made the book finder see books we
hold under old or duplicate Open Library keys. Spec 3, the OL-key and duplicate backfill, waits
until after the cutover to the new site. This spec does not depend on it.

## Purpose

Adding lists is the most important workflow on the site. The goal is to add a new books list
fast and end with every book on it being the right one, without duplicate books or duplicate
authors.

The old wizards (music albums, music songs, games) made a human verify every row, which "took
FOREVER". Here, the admin sees only the rows that might be wrong.

## Decisions (Shane, 2026-10-05/06)

1. **New lists only.** The wizard does not re-verify the ~1,044 migrated lists.
2. **Flag only suspect rows.** Confident matches and confident creations pass through with no review.
3. **Scope: a new shared wizard core, with books as its first user.** Music and games keep running
   on their current code and move onto the core later, one spec each.
4. **Input is pasted HTML or text only.** No URL fetching.
5. **New books are normal books**, not provisional, with AI enrichment queued as usual.
6. **Fix two data-loss flaws in the old wizards now** (section 9).
7. **Steps:** Paste → Parse → Match → Review → Import → Done (approach A). The finder replaces the
   old Enrich and AI-validate steps.
8. **AI-decided matches at high confidence pass through.** The review screen gets a filter for
   spot-checking them.
9. **Undecided flagged rows may stay unlinked** when the admin finishes, after one confirmation.
10. **No creation locks.** Lists are added one at a time. Import creates books one after another
    in a single job, which is what stops duplicate authors (section 6). The only lock is the brief
    row lock that saving wizard progress takes (section 7).
11. **No name-uniqueness rule** on books or authors. Same titles and same names are legitimate.

## Non-goals

- Moving music or games onto the core.
- URL fetching through the page fetcher.
- Bulk actions on the review screen. The old wizards built them and nothing used them.
- The OL-key backfill (spec 3).
- Grouping differently formatted author names within a list ("J.R.R." against "J. R. R.").
  Shane has not seen it happen, so it is out.

## 1. Architecture

### The shared core

The core is domain-agnostic code that every list wizard will use. Books is its first, and for now
only, user. It owns:

- **Steps and progress.** The steps are Paste, Parse, Match, Review, Import, Done. Progress is
  stored in `lists.wizard_state`, through the existing `Services::Lists::Wizard::StateManager`,
  which gets a books subclass naming these steps.
- **Three jobs:**
  - Parse turns pasted content into rows.
  - Match fans out one job per row.
  - Import creates rows one at a time in a single job.
- **The row outcome model** (section 3) and the rules that protect admin decisions (section 8).
- **The screens:** the step screens and the review table, built once as ViewComponents. They
  reuse the existing `Wizard::*` container, progress, step and navigation components, and the
  existing `wizard_step_controller.js` polling.
- **A controller concern** with the step and row actions. Permissions come from the existing
  `Admin::DomainScopedAuth`: write access for every action, delete access for restart.

### The domain adapter

The core talks to a domain through one adapter object. The books adapter supplies:

- **the parser:** `Services::Ai::Tasks::Lists::Books::RawParserTask`, extended with a `subtitle`
  field and told to split it out of the title;
- **the finder query:** builds a `DataImporters::Books::Book::ImportQuery` from a row;
- **the finder:** `DataImporters::Books::Book::Finder`;
- **the importer:** `DataImporters::Books::Book::Importer`;
- **search:** for the review screen's "search our books" autocomplete;
- **display:** how a row and a candidate are shown (title, subtitle, authors, year, list count).

Music and games will add their own adapters when they move over. Names and file layout are left to
the plan, which follows the conventions in `AGENTS.md`: services under `app/lib/services/`, jobs
under `app/sidekiq/`, generators for new classes.

### Admin wiring

- Books gets wizard routes in the `admin_books` namespace. `Admin::Books::ListsController#wizard_path`
  returns the wizard path instead of nil, so the existing "Launch Wizard" button appears.
- The controller test and the Playwright test that assert books has no "Launch Wizard" button are
  updated.

## 2. Parse

- The admin pastes HTML or text into `lists.raw_content`. `simplified_content` is filled on save,
  as today.
- **Large lists.** Paste has the same "large plain-text list (1000+ lines)" checkbox as the old
  wizards. With it on, the content is parsed 100 non-blank lines at a time and positions are
  strictly sequential, ignoring the AI's ranks. One AI call cannot return a 1,000-book list. A
  failed batch fails the whole parse and deletes nothing.
- The parse job runs the books `RawParserTask`. Each parsed book becomes a `ListItem` whose
  metadata holds `rank`, `title`, `subtitle`, `authors` and `year`, at the position given by its
  rank.
- **Subtitles:**
  - `ImportQuery` gains `subtitle`.
  - `OpenLibrarySource` sends it to `/resolve`, which already accepts it.
  - The Exact and OpenSearch sources keep matching on the title.

## 3. Match: one finder run per row

- One Sidekiq job per row, on the `default` queue. Sidekiq's concurrency of 5 caps how many
  `/resolve` calls hit the home server at once.
- Each job:
  - runs the finder with the row as `subject:`, so the `MatchDecision` is linked to the row;
  - saves the Open Library keys a later re-check needs into the row's metadata. Those are the
    accepted key, `decision.duplicates`, and both redirect-source lists.
- Step progress is the number of rows with a decision out of all rows.

### Row outcome

Every row ends in exactly one bucket.

| Bucket | When | Effect |
|---|---|---|
| `matched` | `match.matched?`, confidence certain or high, and not `needs_review?` | The row is linked to the book now, and verified |
| `create` | `match.unmatched?`, `decided_by == :rule`, not `needs_review?`, and `match.external` is an Open Library candidate the service accepted (rule 5) | The book is created in Import |
| `flagged` | Anything else | Shown in Review with its reasons |

### Flag reasons

A row can carry several reasons. Each is shown in plain words:

- `unsure`: the finder said `needs_review?`. That covers medium and low confidence, a fallback,
  a failed source capping high at medium, and rule 2 with several local holders (from #356).
- `not_found`: no candidates at all, or the AI picked none.
- `ai_only_pick`: the AI picked an Open Library work the service did not accept. The wizard never
  creates a book on the AI's word alone.
- `on_list_twice`: two or more rows land on the same local book or the same Open Library work to
  create. Every row involved is flagged. This check runs once, after every row has a decision.
- `import_failed` and `changed_since_match`: set by Import (section 6).

A correct match where the finder also flagged a suspected duplicate pair in our database is
**not** flagged. The pair goes to the existing duplicates queue, and the Done screen reports how
many pairs were raised.

## 4. Review

- **The default view** is every flagged row in list order. A row can be settled and still flagged,
  for example when its import failed. Counts at the top: matched, to
  create, flagged, settled.
- **Filters:**
  - all rows;
  - rows to create;
  - AI-decided rows, the spot-check view for decision 8.
- **Each flagged row shows:**
  - the row as parsed;
  - its reasons;
  - the finder's top candidates, both local books and Open Library works, with title, authors
    and year. Local books also show how many lists they are on.
- **Actions on any row:**
  1. **Pick a local candidate:** link it.
  2. **Create from an Open Library candidate:** move the row to `create`, with that work.
  3. **Search our books:** autocomplete, then link.
  4. **Create from the row's own text:** move the row to `create`, with no Open Library work.
  5. **Edit the row's text and re-match:** the finder runs again on that row only.
  6. **Remove the row from the list.** The row is kept, hidden and settled as `removed`, so a
     re-parse does not bring it back. Import deletes removed rows when it finishes.
- **Every action settles the row** (section 8). It is recorded on the row's `MatchDecision`
  through its existing review fields: verdict, reviewer and time. That way it also appears in
  the match audit pages.
- Linking a book another row already holds is refused with a message, not a 500. This replaces
  the old wizards' swallowed or crashing uniqueness errors.
- **Moving to Import** is always allowed. If unsettled flagged rows remain, the admin confirms
  once ("finish with N rows unlinked?").

## 5. Rows left unlinked

- An unlinked row keeps its parsed text and has no `listable`, so it does not count in rankings.
- The list's admin page shows how many rows are unlinked, so they can be finished later from the
  wizard's Review step.

## 6. Import

- **One Sidekiq job per list.** It goes through the `create` rows one at a time. It never fans
  out a job per row or per author.
- **Each row gets a re-check first.** The job looks in our database for a book holding the
  chosen Open Library key or any key saved with the row at Match.
  - A row created from its own text is checked instead for a book with the same normalized title
    and an agreeing author that was created after the row's Match.
  - If a book turns up, the row links to it and is marked `changed_since_match` for the Done
    summary. It is not flagged.
- **Otherwise it creates the book** through the book importer:
  - as a normal book (`provisional: false`, `enrich: true`), with the row as the subject;
  - using the saved decision, rebuilt the way `SettleEdition#match_from_decision` does it, so
    the finder does not run again.
  - When the admin chose an Open Library work, the new book carries that work key. This holds
    even when the service had not accepted it, because the admin has confirmed it.
  - Authors come in through the importer's existing providers:
    - by Open Library author key when the work has one, which reuses an author already holding
      that key;
    - otherwise by name through the author finder's exact-name check.
- **Duplicate authors.** Rows are created one after another, so a second book by an author we
  did not have finds the author the first book created, through the identifier or exact-name
  check. The old importers spawned a job per creation and raced, which reliably duplicated
  same-named new authors.
- **A failing row** goes back to `flagged` with `import_failed` and the error. The job continues
  with the next row, and the admin can retry from Review.
- **The Done screen** reports:
  - matched;
  - created;
  - linked by the admin;
  - left unlinked;
  - changed since match;
  - duplicate pairs raised.

## 7. State and concurrency rules

- **Row state** lives in `list_items.metadata` under a `wizard` key: bucket, reasons, settled,
  settled by, settled at, and the saved Open Library keys. The finder's decision is reachable
  through the row's existing `match_decisions`. `verified` is true exactly when the row is linked
  to a book that a rule, the admin or Import settled on. Unlinked rows (to create, removed or
  flagged) stay unverified. No migration.
- **Wizard state writes:** a job writes only its own step's entry and re-reads the list first.
  Today a job writes the whole state from a stale copy, which can overwrite a Back or Next click
  made while it ran.

## 8. Protecting admin decisions

- **A settled row** is any row the admin acted on, plus any row Import created or linked.
- **Re-match, re-parse and restart never change or delete a settled row.** The one exception is the
  admin's own "edit the row's text and re-match" on that row.
- **Rows from before the wizard** (migrated, or added on the list page) have no wizard state and
  count as settled.
- **Restart** returns to Paste and deletes only unsettled rows.
- **Re-parse** replaces unsettled rows and needs only write access. A parsed row whose normalized
  title and authors equal a kept row's is not added again. Removed rows are deleted when Import
  finishes, so a re-parse after Import can bring one back.
- **Back** works on every step.

## 9. Fixes to the old wizards (music and games)

1. **Restart keeps verified rows.** `WizardController#restart` stops destroying every list item and
   deletes only unverified ones.
2. **Re-running AI validation leaves hand-made links alone.** Rows marked `manual_link`,
   `manual_musicbrainz_link` or `manual_igdb_link` are skipped:
   - when previous validation flags are cleared (`BaseWizardValidateListItemsJob`);
   - when the validator task selects items, in both batch and non-batch mode.

   The songs test that pins the current behaviour
   (`test/sidekiq/music/songs/wizard_validate_list_items_job_test.rb`) is rewritten.

No other changes to the old wizards. Their other known flaws wait for their move onto the core.

## 10. Testing

**Unit tests:**
- the bucket rules, with one case per bucket and per flag reason, including `on_list_twice` for a
  local book and for an Open Library work;
- the Import re-check, both for a chosen work and for a row created from its own text;
- restart and re-parse keeping settled rows;
- the books adapter;
- `subtitle` through the parser, `ImportQuery` and `/resolve`;
- the state-write rule;
- both old-wizard fixes.

**Duplicate authors:**
- a list with two books by an author we do not hold creates exactly one author;
- the same when one book comes from Open Library and one from the row's text.

**Controller tests** (behaviour only, per `AGENTS.md`):
- every review action;
- linking a book another row holds;
- finishing with unlinked rows;
- permissions: write access for actions, delete access for restart.

**Playwright E2E:** one test runs the full flow on a three-row list:
- two famous books that match;
- one made-up title that is flagged `not_found` and removed in Review;
- then Import and Done.

It uses the real parser and finder, which costs a few cents per run.

`bin/rails test` and `bundle exec standardrb` must pass. CI does not run E2E.

## 11. Docs and rollout

- **Docs:** `docs/features/list-wizard.md` is rewritten around the core and the books adapter,
  with music and games noted as still on the old code.
- **Rollout:** no migration. Books is not live, so merging enables the wizard for admins only.
- **Cost:** one AI parse per list, plus finder AI calls for rows the rules cannot decide. Both run
  on the `fast` role.

## Risks

- **Open Library works can be internally contaminated.** Spec 1's row 142 primary carried another
  book's description. The importer copies only blank fields from an accepted record, as today.
  A wrong description is the realistic failure, and the existing book corrections flow fixes it.
- **AI-decided high matches pass through (decision 8).** The spot-check filter is the only guard.
  The spec 1 replay found no wrong finder answer in 195 rows, but it measured lists the finder
  had already seen.
- **Generic titles** ("Poems", "Stories") abstain or land in `unsure` more often. That is the
  intended behaviour: they are flagged, not guessed.
