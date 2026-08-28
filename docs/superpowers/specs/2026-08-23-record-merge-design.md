# Record Merge: Games, Books, Authors

**Date:** 2026-08-23, revised 2026-08-28
**Status:** Increments 1 (games) and 2 (authors) shipped and deployed. Increment 3 (books) scoped
2026-08-28 against the shipped code and ready for implementation planning.
**Branch:** `worktree-record-merge`

**Reading this document after 2026-08-28:** increments 1 and 2 taught things the original draft did
not know, and the sections below have been revised in place rather than appended to. Where a passage
is marked "corrected during increment 1" or "extended during increment 2", the correction is the
current instruction and the text it replaced is kept only to explain why. The one trap is under
**Admin plumbing**: the original `execute_action?`-gated-on-`can_delete?` instruction is wrong and
would cause a functional regression — read departure 3 first.

## Problem

Admins can merge duplicate music albums, songs, and artists. Books, authors, and games have no
equivalent, so duplicates are removed by deleting one record and losing everything attached to it.

This design adds three mergers built on the music pattern, with four deliberate departures from it.

## Prior art

`Music::{Album,Artist,Song}::Merger` establish the shape, and the new mergers keep it:

- `Klass::Merger.call(source:, target:)` returning
  `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`
- One `ActiveRecord::Base.transaction`: collect affected ranking configurations, move associations,
  reconcile scalars, `source.destroy!`
- Reindexing and ranking jobs scheduled *after* the transaction commits
- A thin `Actions::Admin::<Domain>::Merge<Thing>` subclass of `Actions::Admin::BaseAction`
- A show-page modal using `AutocompleteComponent` posting to a `member post :execute_action` route

Two pieces of plumbing already exist and are reused unchanged: the admin autocomplete endpoints
(`search_admin_books_books_path`, `search_admin_books_authors_path`, and the games equivalent) and
`AutocompleteComponent` itself. Books and authors already honour `exclude_id`; games does not and
gains it.

## Departures from the music pattern

These four were decided during brainstorming and are the substance of this design.

### 1. User-owned data is transferred, not destroyed

The music mergers move only the associations they name; everything else dies with
`source.destroy!`. For music that is nearly harmless. For books and games it silently destroys
reviews people wrote and entries in their personal lists.

New mergers transfer `reviews`, `user_list_items`, `descriptions`, `credits`, and `ai_chats`,
resolving conflicts rather than dropping them on the floor.

### 2. Blank-filling and name absorption

The music mergers reconcile one scalar (earliest `release_year` wins). The new mergers additionally:

- Fill any field that is blank on the survivor from the source
- Absorb the source's title/name **and its own alternates** into the survivor's
  `alternate_titles` / `alternate_names`, deduped

Name absorption matters because it is often the point of the merge: folding
*J.R.R. Tolkien* into *J. R. R. Tolkien* should leave the deleted spelling searchable. Both columns
are GIN-indexed and both feed `as_indexed_json`.

The survivor's existing non-blank values always win. There is no field-level "pick a winner" UI.

### 3. Merge requires delete permission

`Music::{Album,Artist,Song}Policy#execute_action?` is gated on `can_write?` (editor and above), but
merge *deletes a record*, and `ApplicationPolicy#destroy?` is gated on `can_delete?` (moderator and
above). A **domain-scoped** editor who cannot press Delete can today delete an album by merging it.
(Global admins and global editors pass both checks via `global_role?`, so they are unaffected — the
hole is specific to per-domain roles.)

**Corrected during increment 1 — gate the ACTION, not the endpoint.** The original design here said to
gate `execute_action?` itself on `can_delete?`. That is wrong, and shipping it would have caused a
functional regression. `execute_action` is a **shared** endpoint: `admin/music/albums/show.html.erb`
routes "Generate AI Description" through it, and `artists/show.html.erb` routes both "Generate AI
Description" and "Refresh Artist Ranking". Only songs are merge-only. Blanket-gating the endpoint on
`can_delete?` would strip domain-scoped editors of non-destructive abilities they have today.

The implemented design instead:

- `Actions::Admin::BaseAction.destructive?` returns `false` by default.
- Every `Merge*` action overrides it to `true`.
- `execute_action?` on every policy stays `global_role? || domain_role&.can_write?` — write access is
  the floor for the shared endpoint.
- Each controller calls `authorize @record, :destroy? if action_class.destructive?` immediately after
  resolving the action class and before invoking it.

This closes the hole for merges while preserving existing permissions for everything else, and it
generalises: any future destructive action gets the right gate by declaring itself destructive.
Increments 2 and 3 must follow this pattern — a `Merge*` action that omits the `destructive?`
override leaves the gate silently inert.

The load-bearing test lives at the **controller** level (a domain-scoped editor is rejected, a
moderator is allowed), not in the policy unit test, because the controller is the real entry point.

The music mergers' other gap — silently discarding descriptions, credits, AI chats, and personal-list
entries — is explicitly **not** backported. The new mergers do it right; music keeps shipped
behaviour.

### 4. Book merge does not import authors onto a book that has them

Duplicate books are usually bad imports, and a bad import's `book_authors` usually point at
duplicate *author* rows. Transferring them leaves the surviving book showing two rows for the same
person — visible on the public page, in `author_names` in the search index, and in author rankings,
which derive from an author's books.

Therefore, in **book merge only**:

- `book_authors` transfer only if the survivor has **zero** authors
- `credits` transfer only if the survivor has **zero** credits (evaluated independently)
- Either way, the success message names what the source had and was not transferred

In **author merge** this concern does not apply — repointing `book_authors` is the entire purpose
and cannot duplicate a person — so it stays a plain repoint-or-drop.

Note the two features rescue each other: merging the duplicate *author* first makes `book_authors`
dedupe on `author_id` automatically. The default does not rely on the admin doing it in that order.

### Explicitly out of scope

**Dead URLs are accepted.** Merging deletes the source, so `/books/<source-id>` (the legacy canonical
URL, ~156k pages indexed) and `/book/<source-slug>` return 404 with no trail back. There is no
slug-history or redirect table anywhere in the app and none is added. Decided deliberately; matches
music.

**The confirmation dialog must describe what actually happens.** Increment 1 needed three review
rounds on this string. Several associations dedupe against what the survivor already has and **drop**
the duplicate's copy rather than merging it — including entries in real users' personal saved lists,
and including curated list entries (whose `position` is lost, only `verified` surviving). And
`reconcile_scalars` mutates the *survivor*: blank fields are filled, and `release_year` is
**overwritten** when the duplicate's is earlier. Enumerating exceptions per-association just surfaces
the next one; state one general collision caveat that is true of every dedup path. See
`app/views/admin/games/games/show.html.erb` for the wording that survived review.

The book modal needs two things the games wording has no equivalent for: that a **review** by a user
who has reviewed both books keeps the survivor's and discards the duplicate's, and that authors and
credits transfer **only onto a book that has none** — with the success message naming what was left
behind. Neither is a general collision caveat; both are book-specific rules an admin has to know
before pressing the button.

Also out of scope: any merge preview or dry-run, field-level conflict resolution UI, and undo.

## Conflict patterns

Three patterns recur. Each association below is labelled with one.

- **Repoint** — no unique constraint can collide; `update_all` the foreign key.
- **Repoint-or-drop** — a unique index exists on (parent, X); if the survivor already has that X,
  discard the source's row, else repoint it.
- **Repoint-or-merge** — same, but the losing row carries a payload worth salvaging first.

## `Books::Book` merger

`app/lib/books/book/merger.rb`

| Association | Pattern | Detail |
|---|---|---|
| `editions` | Repoint | **Must precede `destroy_source_book`** — see "Ordering constraints" below |
| `book_authors` | Gated | Transfer only if survivor has zero authors; then renumber `position` 1..n |
| `credits` | Gated | Transfer only if survivor has zero credits |
| `identifiers` | Repoint-or-drop | on (`identifier_type`, `value`) |
| `book_countries` | Repoint-or-drop | on `country_id` |
| `series_books` | Repoint-or-drop | on `series_id` |
| `category_items` | Copy-or-skip | `find_or_create_by(category_id:)` on the survivor; the source's rows then die with it (the music pattern) |
| `list_items` | Repoint-or-merge | Promote survivor to `verified: true` if either was; **skip auto-generated lists entirely**, see below |
| `user_list_items` | Repoint-or-drop | on `user_list_id`; `position` is list-scoped so it stays valid |
| `reviews` | Repoint-or-drop | on `user_id`; see below |
| `review_summary` | Derived | Dies with source; survivor's recomputed |
| `descriptions` | Repoint-or-drop | on (`kind`, `locale`, `source`, `source_name`); see below |
| `images` | Repoint | Demote moved images to `primary: false` if survivor has a primary |
| `external_links`, `ai_chats` | Repoint | |
| `book_relationships` | Repoint-or-drop | Skip self-referential; `find_or_create_by` on (`related_book_id`, `relation_type`) |
| `inverse_book_relationships` | Repoint-or-drop | Repoint `related_book_id`; drop if self-referential or duplicate |
| `corrections` | **Dropped** | Deliberately dies with the source — decided 2026-08-28, see below |
| `ranked_items` | Derived | Collected for recalc, then die with source |
| `Books::Series#representative_book_id` | Repoint | Inbound FK, `on_delete: nullify` — repoint or it silently blanks |

**Scalars.** Blank-filled: `subtitle`, `sort_title`, `book_length`, `page_range`, `word_count`,
`description`, `original_language_id`, `default_edition_id`. Earliest wins:
`first_published_year`. Absorbed: `alternate_titles`.

Two columns are deliberately **excluded** from blank-fill. `book_kind` is a NOT NULL enum with a
default, so it is never blank — the same reasoning that keeps `kind` out of the author merger's
list. And `amazon_enriched_at` marks that the Amazon lookup already ran: the survivor keeps its own
value and the duplicate's is discarded, because the merge hands the survivor a batch of newly
absorbed editions that Amazon has never seen. Filling a blank stamp from the duplicate would mark
the survivor "done" and let the enrichment sweep skip exactly the book that most needs it.

**Reviews** use a specific shape to avoid a callback storm. `Review` has an
`after_commit :recalculate_summary`, so a per-record `update!` would fire N recalculations:

```ruby
Review.where(reviewable: source)
      .where(user_id: Review.where(reviewable: target).select(:user_id))
      .delete_all
Review.where(reviewable: source).update_all(reviewable_id: target.id)
Services::Reviews::SummaryRecalculator.recalculate("Books::Book", target.id)
```

A subquery rather than a plucked id list: this codebase has already hit PostgreSQL's 65,535
bind-parameter cap with a large `IN`. `SummaryRecalculator` is documented as the only writer of
`review_summaries`. The recalculation runs inside the transaction.

**Descriptions** carry two unique indexes: one on
(`describable_type`, `describable_id`, `kind`, `locale`, `source`, `source_name`) with
`nulls_not_distinct`, and a partial one enforcing a single `rank = 1` per (type, id, kind, locale).
Moved rows are forced to `rank: 0` where the survivor already holds a preferred row for that
kind+locale.

**Auto-generated lists are skipped, and the generated list is rebuilt after commit.** Both were
learned after increments 1 and 2 shipped and are already live in the games and music mergers
(commits `7ce4d6d5`, `d4f7d4de`). `merge_list_items` writes through `update!`/`create!`, which
`ListItem`'s own validation rejects once the list is `auto_generated?` — so a book that happens to
sit on "Our Users' Favorite Books of All Time" would turn an admin merge into a 500. Skipping loses
nothing directly, because the generator rewrites that list from the underlying user favorites, which
the merge has already repointed. But the skipped row then dies with the source, leaving the generated
list one item short, and `schedule_ranking_recalculation`'s `CalculateRankingsJob.perform_in(5.minutes, …)`
would read that short list before the nightly 03:00 regeneration ever runs. So `run_post_commit_steps`
also calls `GenerateUserFavoritesListsJob.perform_async("Books::UserList")`, which queues comfortably
inside that five-minute window. Only a full rebuild produces the correct combined score, voter count
and position for the survivor; a repointed row would not.

**`corrections` are deliberately dropped.** `Books::Book` includes `Correctable`, which declares
`has_many :corrections, as: :correctable, dependent: :destroy`, so the source's corrections are
destroyed with it. That is the decision, not an oversight — recorded here so it is not re-raised as
a data-loss defect later.

Measured against the 455 book corrections in development: 29 (6.4%) mention duplication or merging
("Same as 10369", "Already listed as 'Out of Africa' by Isak Dinesen #402", "Delete. Duplicate of
…/books/123"), 20 of them still pending. That base rate understates the picture at merge time, since
a duplicate report is frequently *why* an admin is merging the record — the corrections attached to a
record about to be merged skew far more duplicate-heavy than the corpus does. A merge is the admin
actioning those reports, and moving them to the survivor would leave stale "this is a duplicate"
rows in the pending queue for a book that is no longer a duplicate of anything.

The accepted cost is real and worth naming: the other 93.6% are substantive ("the nationality should
be Irish", "cover image is from a different book", "the publication date should be 1908"), and a
handful are **mixed** — one row carrying both a duplicate report and a genuine fix ("Shouldn't it be
merged with the main 1001 Nights entry? Either way, date should be CE not BCE"). Those fixes are lost
when the source is destroyed. No rule separates them: the duplicate reports are free-text notes, and
notes-only corrections are otherwise substantive, so neither `status` nor the presence of
`correction_fields` is a usable discriminator.

`Music::Album` and `Games::Game` are `Correctable` too, and the correction form is routed and live on
both domains. Their mergers destroy corrections the same way, which under this decision is **correct
behaviour, not a bug** — there is no backport to do.

## `Games::Game` merger

`app/lib/games/game/merger.rb`

| Association | Pattern | Detail |
|---|---|---|
| `game_companies` | Repoint-or-drop | on `company_id`, **OR-ing `developer` and `publisher`** so a source row marking publisher is not lost |
| `game_platforms` | Repoint-or-drop | on `platform_id` |
| `child_games` | Repoint | Repoint `parent_game_id` to the survivor. The association is `dependent: :nullify`, so doing nothing orphans the subtree. If a child *is* the survivor, nullify instead |
| `identifiers`, `category_items`, `list_items`, `user_list_items`, `images`, `external_links`, `descriptions` | As book | |
| `ranked_items` | Derived | |

**Scalars.** Blank-filled: `description`, `series_id`. Earliest wins: `release_year`.
`parent_game_id` is filled only if blank **and** the survivor is not a `main_game`
(`parent_game_valid_for_type` rejects that) **and** it would not create a cycle.

Games have no reviews, credits, or AI chats.

## `Books::Author` merger

`app/lib/books/author/merger.rb`

| Association | Pattern | Detail |
|---|---|---|
| `book_authors` | Repoint-or-drop | on `book_id`; **fans out reindex requests**, see below |
| `credits` | Repoint-or-drop | Dedup on (`creditable_type`, `creditable_id`, `role`) — no DB constraint, so dupes are ours to prevent |
| `author_relationships` | Repoint-or-drop | Repoint `from_author_id`, skip self-relations, `find_or_create_by` on (`to_author_id`, `relation_type`) |
| `inverse_author_relationships` | Repoint-or-drop | Repoint `to_author_id`; drop if self-referential or duplicate |
| `identifiers`, `category_items`, `images`, `external_links`, `descriptions`, `ai_chats` | As book | |
| `ranked_items` | Derived | |

**Scalars.** Blank-filled: `sort_name`, `birth_year`, `death_year`, `gender`, `description`.
Survivor always wins: `kind`, `exclude_from_rankings` (never blank). Absorbed: `alternate_names`.

Authors are not listable — no `list_items` or `user_list_items`.

**Two asymmetries specific to author merge:**

*Books must be reindexed explicitly.* `Books::Book#as_indexed_json` embeds `author_names` and
`author_ids`, but `Books::Author#queue_books_for_reindexing` only fires on a **name** change and only
for the source's books, which are about to be reassigned. The merger collects `source.book_ids`
before repointing and bulk-inserts a `SearchIndexRequest` per affected book, batched to stay under
the bind-parameter cap.

*Rankings recalculate differently.* Books and games use `BulkCalculateWeightsJob` +
`CalculateRankingsJob` keyed on affected configuration ids, because their rankings derive from
lists. Author rankings derive from *book* rankings, so author merge fires
`Books::CalculateAuthorRankingsJob.perform_async` with no arguments (it resolves
`Books::Authors::RankingConfiguration.default_primary` itself). Conversely, a *book* merge gets
author recalculation for free: `CalculateRankingsJob` already cascades into that job for any
`Books::RankingConfiguration`.

## Ordering constraints

Most of the merge is order-independent. These six are not:

0. **Both rows are locked first.** `lock_books` takes `FOR UPDATE` on the source and the survivor in
   ascending id order, as the first statement inside the transaction. Without it two admins merging
   the same duplicate can both pass the guards and the loser's `destroy!` silently affects zero rows
   — `books_books` has no `lock_version`, so Rails never checks the affected count — reporting a
   completed merge that moved nothing. Ascending id order is what stops two merges with swapped
   source and target from deadlocking. It must precede `reconcile_scalars`, because `lock!` refuses
   a record with unsaved changes.
1. **Ranking configuration ids are collected first.** Once `source.destroy!` cascades its
   `ranked_items`, the affected set is unrecoverable.
2. **Editions move before the source is destroyed.** The transaction has exactly one persistence
   point, `target_book.save!`, and it runs after both `merge_all_associations` (which includes
   `merge_editions`) and `reconcile_scalars` (which fills `default_edition_id`) — so the relative
   order of those two calls has no observable effect; swapping them changes nothing. What is
   load-bearing is that `merge_editions` precedes `destroy_source_book`. `books_editions.book_id`
   is `dependent: :destroy` on `Books::Book`, and `books_books.default_edition_id` is a foreign key
   to `books_editions` with `on_delete: :nullify` at the database level. If an edition were still
   owned by the source when `destroy_source_book` cascaded, the DB would delete it and nullify
   *any* row's `default_edition_id` pointing at it — including the survivor's, even though
   `target_book.save!` already committed that value. Moving the editions first empties that
   cascade before it runs, so there is nothing left for the source's destroy to delete.
3. **Author merge collects `source.book_ids` before repointing `book_authors`**, or there is no way
   to know which books changed authorship.
4. **"Did the survivor have authors/credits?" is captured before any writes**, so the gate decision
   and the report of what was not transferred read the same state.
5. **Inbound FKs are repointed before the destroy.** `books_series.representative_book_id` is
   `on_delete: nullify` and `games_games.parent_game_id` is `dependent: :nullify`; do nothing and
   both silently blank instead of following the merge.

## Transaction boundary

Inside one `ActiveRecord::Base.transaction`: the row locks, every association move, the scalar
reconciliation, the review summary recalculation, `target.save!`, and `source.destroy!`.

Outside, after commit: the survivor's `SearchIndexRequest`, the fan-out of reindex requests for an
author merge's affected books, the generated-favorites rebuild, and all ranking jobs. Jobs stay
outside because `perform_async` writes to Redis, which a rollback cannot undo — the job would wake
describing a merge that never happened.

**Book merge fans out no reindex requests beyond the survivor's own.** Author merge needs the
fan-out because `Books::Book#as_indexed_json` embeds `author_names` and `author_ids`, so moving
authorship changes every one of those books' documents. The converse does not hold:
`Books::Author#as_indexed_json` carries only `name`, `alternate_names` and `category_ids`, so a book
merge changes no author document. This asymmetry is deliberate — absence of a fan-out in the book
merger is the correct design, not a copy-paste omission from the author merger.

Unindexing the source is automatic: `SearchIndexable` fires `unindex_item` on destroy.

Unlike the music mergers, the new mergers check
`Services::BooksMigration.search_indexing_suppressed?` before creating index requests, matching what
`SearchIndexable` already does.

## Failure handling

The music rescue ladder verbatim: `ActiveRecord::RecordInvalid`, then
`ActiveRecord::RecordNotUnique`, then bare `StandardError`, each returning
`Result.new(success?: false, data: nil, errors: [...])`.

Because everything mutating is inside the transaction, a failed merge leaves both records exactly as
they were. This is also what catches blank-fill validation failures: if filling `parent_game_id`
trips `parent_game_valid_for_type`, `target.save!` raises and the whole merge rolls back rather than
half-applying.

Guards evaluated **before** the transaction opens, returning an error result rather than raising:
self-merge, and for games a parent/child cycle check.

### Post-commit steps must not fail the merge

**Added during increment 1.** The rescue ladder above guards the *transaction*. The reindex request
and the ranking jobs run **after** it commits, and they do real fallible I/O — `SearchIndexRequest.create!`
and Redis `perform_async`/`perform_in`. Leaving them inside the same method-level rescue means a Redis
blip returns `success?: false` for a merge that already happened: the source is destroyed, the target
updated, and the admin is told it failed. A retry then fails with "not found".

The rationale for the ladder — "everything mutating is inside the transaction" — simply does not hold
for these steps. So they are wrapped separately:

```ruby
def run_post_commit_steps
  reindex_target
  schedule_ranking_recalculation
  regenerate_user_favorites_list
rescue => error
  Rails.logger.error("... committed, but post-commit follow-up failed: #{error.class}: #{error.message}")
  @stats[:post_commit_error] = error.message
end
```

**Extended during increment 2 — a commit callback can raise *after* the commit too.**
`SearchIndexable`'s `after_commit` hooks (the survivor's `save!`, the source's `destroy!`) fire as the
transaction block exits, which is after the commit, and Rails propagates anything they raise straight
out of that block into the method-level rescue ladder. Reporting `success?: false` there tells the
admin a merge failed when the source is already permanently deleted, and their retry then fails with
"not found" — the same failure mode, arriving through a different door. So each rescue routes through
a shared `result_for_raised`, which reports success when the merge in fact committed:

```ruby
def merge_committed?
  @transaction_body_completed && !::Books::Book.exists?(@source_book_id)
end
```

Both halves are load-bearing. The flag alone would misread a COMMIT that itself failed (a deferred
constraint) as success. The missing row alone would misread a merge that never started because a
concurrent merge had already consumed the source — which is precisely what `lock_books` raises on.

**`success?` means "the merge committed"** — not "reindexing and ranking also succeeded". That is the
contract the admin UI reports. The shipped modal (`app/views/admin/games/games/show.html.erb`) does
not say so explicitly — its copy describes what data moves, what's discarded on collision, and what
the survivor absorbs, not this success/post-commit-failure distinction; a post-commit failure instead
surfaces via a warning message appended to the success text (see `Actions::Admin::Games::MergeGame`).
This is a deliberate divergence from the three music mergers, which still have the unfixed defect.
Increments 2 and 3 follow the corrected pattern.

## Admin plumbing

As of 2026-08-23, no books or games controller had `execute_action` and `Actions::Admin::` had no
books or games namespace. Increments 1 and 2 added both for games and authors; only
`Admin::Books::BooksController` still lacks it. Each of the three resources gains:

1. `member do post :execute_action end` in `config/routes.rb`
2. An `execute_action` method modelled on `Admin::Music::AlbumsController#execute_action`,
   constantizing into its own domain's namespace, plus an `allowed_action_names` override —
   `validate_action_name!` itself is already inherited from `Admin::BaseController`
3. `:execute_action` added to **both** existing `before_action` lists, the record setter and the
   `authorize_*`
4. `execute_action?` on the policy

**On item 4, read departure 3 above before writing it.** `execute_action?` is
`global_role? || domain_role&.can_write?` — write access is the floor for a shared endpoint. It is
**not** gated on `can_delete?`; that was this document's original instruction and increment 1
established it was wrong. The delete gate lives in the controller, as
`authorize @record, :destroy? if action_class.destructive?`, immediately after the action class is
resolved and before it is invoked. `Books::BookPolicy` is currently bare and inherits nothing named
`execute_action?`, so omitting it raises `NoMethodError` rather than failing open.

Plus `exclude_id` support in `Admin::Games::GamesController#search`. Books and authors already have it.

**Action classes:** `Actions::Admin::Books::MergeBook`, `Actions::Admin::Books::MergeAuthor`,
`Actions::Admin::Games::MergeGame`. Each validates that the source id is present and the confirm
checkbox is ticked, looks up the source, rejects a self-merge, delegates to the merger, and returns
`succeed`/`error`.

**UI:** a Merge button beside Edit/Delete in each show header, wrapped in `current_user_can_delete?`
to match the gating, opening a modal ported from the artist merge modal — `AutocompleteComponent`
against the existing search endpoint with `exclude_id`, a confirm checkbox, a `btn-warning` submit.
No new JavaScript, no new component.

`current_user_can_delete?` is a `helper_method` on `Admin::BaseController`, so it is available in all
three views. Note that `app/views/admin/games/games/show.html.erb` currently guards **nothing** — its
Edit link is ungated, unlike the books views — so the Merge button will be the first role-guarded
control on that page. That existing inconsistency is a UI-only gap (the controller's `authorize`
still protects the action) and is **not** in scope here.

## Namespace hazard

Inside `module Books` or `module Games`, a bare `Books::Book` resolves to the **nested** module.
Every reference is root-anchored as `::Books::Book`, `::Games::Game`, `::Books::Author` — in
production code **and** in test files. This has bitten this codebase three or more times and presents
as a confusing `NameError`.

## Testing

Layers: three merger unit tests, three action-class tests, three controller tests, three E2E specs,
plus policy tests for the music correction.

Merger tests mirror `test/lib/music/artist/merger_test.rb`: clear fixture `ranked_items` in `setup`,
then one test per rule. **Each rule needs both branches** — "the source's country moved across" *and*
"the source's country was dropped because the survivor already had it." Testing only the transfer
branch is how a repoint-or-drop silently degrades into a plain repoint and starts raising
`RecordNotUnique` in production.

Ranking jobs run inline under this suite's Sidekiq config and are intercepted with Mocha, as the
album merger test already does:

```ruby
BulkCalculateWeightsJob.expects(:perform_async).with(config.id)
CalculateRankingsJob.expects(:perform_in).with(5.minutes, config.id)
```

**Authorization gets a real test:** a domain editor is rejected from `execute_action` while a
moderator is allowed. That is the entire point of gating on `can_delete?` and it is invisible if only
the happy path is covered.

**Fixtures.** No new files needed. `books/authors.yml` already has `king` and `bachman` — a genuine
pseudonym pair — plus `tolstoy`/`garnett` for translator credits and `excluded_placeholder` for the
rankings-exclusion flag. Games has `breath_of_the_wild` and `tears_of_the_kingdom`, enough for
source/target; parent/child cases are built inline in the test, as the music merger tests already do.

**Never run `ActiveRecord::FixtureSet.create_fixtures`** — it truncates every table it names, and the
books data exists only in development.

### Test hazards specific to this work

- **Merger assertions pass against dead code unusually easily.** "The survivor now has category X" is
  true whether the merge moved it or the fixture already had it. Every assertion must be verified by
  deleting the line under test and confirming it goes red.
- **Root-anchor constants in tests**, per the namespace hazard above.
- **Reindex tests need a scalar confound neutralised first.** Both learned in increment 2. Scalar
  reconciliation nearly always dirties the survivor — absorbing the duplicate's title into
  `alternate_titles` alone does it — and the resulting `target.save!` fires `SearchIndexable`'s own
  `after_commit`, creating exactly the `index_item` row the test means to attribute to the merger's
  explicit reindex. Without a `neutralize_scalar_confound` helper (see
  `test/lib/books/author/merger_test.rb`) those tests pass against a merger that does no reindexing
  at all. Book merge absorbs `alternate_titles`, so it carries the identical confound.
- **Stub `GenerateUserFavoritesListsJob.perform_async` in any test that hand-builds an
  auto-generated-list scenario.** Sidekiq runs inline in this suite, so the real job rebuilds that
  fixture list from live `user_list_items` and wipes the `ListItem` rows the test just crafted.
- **`ps aux | grep "[r]ails test"` before running the suite** — this worktree shares
  `the_greatest_test` with the main checkout and with any other agent's worktree.
- Minitest is 6.x: `assert_nil`, never `assert_equal nil`.

E2E gets one Playwright spec per merge flow in `web-app/e2e/tests/`. **Deliberate constraint, not an
omission:** the spec does not perform a real merge. E2E runs against the **development** database —
the one with irreversible, hours-to-rebuild books data (see CLAUDE.md) — and a merge destroys a row
with no undo. The shipped `games-merge.spec.ts` instead drives the modal up to (but not past) the
point of submission: opening it from the show page and confirming the confirmation-checkbox guard,
never clicking "Merge Game" with a real source selected. This constraint applies equally to
increments 2 and 3. Local only — CI does not run Playwright.

## Increments

Three increments, each its own PR.

**Increment 1 — Games merge, shared plumbing, music policy fix.**
Games is the simplest model: no reviews, credits, or AI chats. It establishes the
`Actions::Admin::Games` namespace, the `execute_action` route/controller/policy pattern, and the
modal port on the easiest case. The three-line music policy correction rides along as the same
concern. Includes `exclude_id` on the games search endpoint.

**Increment 2 — Author merge.**
Bidirectional relationships, credits, the book-reindex fan-out, and the different ranking job.
Landing before book merge means author merges can precede book merges, which is the order that makes
the author-gate question moot.

**Increment 3 — Book merge.**
Everything hard, on a proven pattern: reviews plus summary recalculation, editions plus
`default_edition_id`, series representative, countries, bidirectional relationships, and the
authors/credits gate.

Increment 3 was scoped on 2026-08-28, after increments 1 and 2 had shipped and the mergers had moved
on from this document. An audit of the codebase against the table above found the plumbing exactly as
predicted — `Books::BookPolicy` is bare (no `execute_action?`, so Pundit would raise `NoMethodError`),
`Admin::Books::BooksController` has no `execute_action`, and `resources :books` has no
`member post :execute_action`. `exclude_id` is already supported on the books search endpoint, and
`test/lint/merge_actions_destructive_test.rb` discovers `MergeBook` by filesystem glob, so neither
needs work.

It also found five things this document did not yet say, all now folded into the sections above: the
auto-generated-list skip and the generated-favorites rebuild; `lock_books` and the
`result_for_raised`/`merge_committed?` pattern; the absence of an author reindex fan-out; the
`corrections` decision; and `amazon_enriched_at`'s exclusion from blank-fill.

Two non-obvious facts confirmed against the schema while scoping, worth not re-deriving:
`Books::Book` declares no friendly_id `:history`, so there are no `friendly_id_slugs` rows to migrate
or clean up; and `books_editions` carries no unique index on `book_id`, so editions are a plain
repoint with no collision case.

## Files

**New:**
- `app/lib/games/game/merger.rb` + test
- `app/lib/books/author/merger.rb` + test
- `app/lib/books/book/merger.rb` + test
- `app/lib/actions/admin/games/merge_game.rb` + test
- `app/lib/actions/admin/books/merge_author.rb` + test
- `app/lib/actions/admin/books/merge_book.rb` + test
- `e2e/tests/` — one spec per merge flow
- `docs/` — a doc per merger, per the documentation convention

**Modified:**
- `config/routes.rb` — three `member post :execute_action`
- `app/controllers/admin/games/games_controller.rb` — `execute_action`, `exclude_id` in `search`
- `app/controllers/admin/books/books_controller.rb` — `execute_action`
- `app/controllers/admin/books/authors_controller.rb` — `execute_action`
- `app/policies/games/game_policy.rb`, `app/policies/books/book_policy.rb`,
  `app/policies/books/author_policy.rb` — `execute_action?` (see the correction under Admin plumbing:
  `can_write?`, with the delete gate in the controller)
- `app/policies/music/{album,artist,song}_policy.rb` — same correction
- `app/views/admin/games/games/show.html.erb`, `app/views/admin/books/books/show.html.erb`,
  `app/views/admin/books/authors/show.html.erb` — Merge button and modal
- `CLAUDE.md` — spec location corrected to `docs/superpowers/specs/` (done)

**Remaining for increment 3**, everything else above having shipped in increments 1 and 2:
`app/lib/books/book/merger.rb` + test, `app/lib/actions/admin/books/merge_book.rb` + test,
`e2e/tests/books/admin/books-merge.spec.ts`, a `member post :execute_action` on `resources :books`,
`execute_action` + `allowed_action_names` on `Admin::Books::BooksController` + its controller test,
`execute_action?` on `Books::BookPolicy`, the Merge button and modal in
`app/views/admin/books/books/show.html.erb`, and an update to `docs/features/record-merge.md` —
which currently says books are "not yet built" in two places.
