# Record Merge: Games, Books, Authors

**Date:** 2026-08-23
**Status:** Design approved, ready for implementation planning
**Branch:** `worktree-record-merge`

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

The three new policies gate `execute_action?` on `can_delete?`, and the three music policies are
corrected to match. This mirrors the existing `require_domain_write!` vs `require_domain_delete!`
distinction already documented in `Admin::DomainScopedAuth`.

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
| `editions` | Repoint | **Must precede `default_edition_id`** |
| `book_authors` | Gated | Transfer only if survivor has zero authors; then renumber `position` 1..n |
| `credits` | Gated | Transfer only if survivor has zero credits |
| `identifiers` | Repoint-or-drop | on (`identifier_type`, `value`) |
| `book_countries` | Repoint-or-drop | on `country_id` |
| `series_books` | Repoint-or-drop | on `series_id` |
| `category_items` | Copy-or-skip | `find_or_create_by(category_id:)` on the survivor; the source's rows then die with it (the music pattern) |
| `list_items` | Repoint-or-merge | Promote survivor to `verified: true` if either was |
| `user_list_items` | Repoint-or-drop | on `user_list_id`; `position` is list-scoped so it stays valid |
| `reviews` | Repoint-or-drop | on `user_id`; see below |
| `review_summary` | Derived | Dies with source; survivor's recomputed |
| `descriptions` | Repoint-or-drop | on (`kind`, `locale`, `source`, `source_name`); see below |
| `images` | Repoint | Demote moved images to `primary: false` if survivor has a primary |
| `external_links`, `ai_chats` | Repoint | |
| `book_relationships` | Repoint-or-drop | Skip self-referential; `find_or_create_by` on (`related_book_id`, `relation_type`) |
| `inverse_book_relationships` | Repoint-or-drop | Repoint `related_book_id`; drop if self-referential or duplicate |
| `ranked_items` | Derived | Collected for recalc, then die with source |
| `Books::Series#representative_book_id` | Repoint | Inbound FK, `on_delete: nullify` — repoint or it silently blanks |

**Scalars.** Blank-filled: `subtitle`, `sort_title`, `book_length`, `page_range`, `word_count`,
`description`, `original_language_id`, `default_edition_id`. Earliest wins:
`first_published_year`. Absorbed: `alternate_titles`.

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

Most of the merge is order-independent. These five are not:

1. **Ranking configuration ids are collected first.** Once `source.destroy!` cascades its
   `ranked_items`, the affected set is unrecoverable.
2. **Editions move before `default_edition_id` is filled**, or the survivor's default edition FK
   points at a row owned by the record about to be deleted.
3. **Author merge collects `source.book_ids` before repointing `book_authors`**, or there is no way
   to know which books changed authorship.
4. **"Did the survivor have authors/credits?" is captured before any writes**, so the gate decision
   and the report of what was not transferred read the same state.
5. **Inbound FKs are repointed before the destroy.** `books_series.representative_book_id` is
   `on_delete: nullify` and `games_games.parent_game_id` is `dependent: :nullify`; do nothing and
   both silently blank instead of following the merge.

## Transaction boundary

Inside one `ActiveRecord::Base.transaction`: every association move, the scalar reconciliation, the
review summary recalculation, `target.save!`, and `source.destroy!`.

Outside, after commit: the survivor's `SearchIndexRequest`, the fan-out of reindex requests for an
author merge's affected books, and all ranking jobs. Jobs stay outside because `perform_async` writes
to Redis, which a rollback cannot undo — the job would wake describing a merge that never happened.

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

## Admin plumbing

No books or games controller has `execute_action`, and `Actions::Admin::` has no books or games
namespace. Each of the three resources gains:

1. `member do post :execute_action end` in `config/routes.rb`
2. An `execute_action` method modelled on `Admin::Music::AlbumsController#execute_action`,
   constantizing into its own domain's namespace
3. `:execute_action` added to the existing `before_action :authorize_*` list
4. `execute_action?` on the policy, gated on `can_delete?`

Plus `exclude_id` support in `Admin::Games::GamesController#search`.

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
- **`ps aux | grep "[r]ails test"` before running the suite** — this worktree shares
  `the_greatest_test` with the main checkout and with any other agent's worktree.
- Minitest is 6.x: `assert_nil`, never `assert_equal nil`.

E2E gets one Playwright spec per merge flow in `web-app/e2e/tests/`, driving the modal against the
real autocomplete. Local only — CI does not run Playwright.

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
  `app/policies/books/author_policy.rb` — `execute_action?` gated on `can_delete?`
- `app/policies/music/{album,artist,song}_policy.rb` — same correction
- `app/views/admin/games/games/show.html.erb`, `app/views/admin/books/books/show.html.erb`,
  `app/views/admin/books/authors/show.html.erb` — Merge button and modal
- `CLAUDE.md` — spec location corrected to `docs/superpowers/specs/` (done)
