# Record Merge

## Overview

Record merge lets an admin fold one duplicate record ("source") into another ("target"),
transferring the source's associations and user-owned data onto the target and then destroying
the source. It replaces the old workflow of deleting the duplicate outright, which silently
discarded everything attached to it — identifiers, list entries, personal-list entries, images,
categories, and more.

`Music::{Album,Artist,Song}::Merger` shipped this pattern first. This increment ports it to games
(`::Games::Game::Merger`, `app/lib/games/game/merger.rb`) and authors (`::Books::Author::Merger`,
`app/lib/books/author/merger.rb`), with departures the music mergers don't have — moving
associations the music mergers drop on the floor, and checking search-indexing suppression before
writing an index request. Books are planned as increment 3 of the same design; **this doc covers
games and authors**, which is what exists today. For the full three-domain design, including the
per-association table for books, see `docs/superpowers/specs/2026-08-23-record-merge-design.md`.

An admin reaches it from a game's admin show page via a "Merge" button, gated on delete permission
(moderator role and above) rather than the lower write permission other actions on that page use —
merge deletes a record, so it needs the same permission delete does. The button opens a modal that
searches for the duplicate to merge in, then submits to the game's `execute_action` route, which
dispatches to `Actions::Admin::Games::MergeGame` and from there to the merger. An author's admin
show page offers the same button, dispatching via the author's own `execute_action` route to
`Actions::Admin::Books::MergeAuthor` instead.

## Calling the merger

```ruby
result = ::Games::Game::Merger.call(source: duplicate_game, target: canonical_game)
result = ::Books::Author::Merger.call(source: duplicate_author, target: canonical_author)
```

Both return the same `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`:

- `success?` — `true` if the merge committed.
- `data` — the target game (with merged data) on success, `nil` on failure.
- `errors` — an array of messages on failure, empty on success.

A self-merge (`source.id == target.id`) is rejected before any transaction opens. Every other
failure — a validation error, a unique-constraint violation, anything else raised mid-merge —
rolls the whole transaction back and is reported the same way, so a failed merge always leaves
both records exactly as they were before the call.

## Conflict-resolution patterns

Every association the merger moves falls into one of three patterns:

- **Repoint** — no unique constraint can collide, so the foreign key is just reassigned to the
  target. `external_links` and `child_games` (games' own `parent_game_id`) are repoints.
- **Repoint-or-drop** — a unique index exists on (parent, some other column). If the target
  already has a row for that column's value, the source's row is discarded instead of colliding;
  otherwise it's repointed. `identifiers` (on identifier type + value), `game_platforms` (on
  platform), and `descriptions` (on kind/locale/source/source_name) all follow this shape.
- **Repoint-or-merge** — same collision check as repoint-or-drop, but the losing row carries a
  payload worth salvaging before it's discarded. `list_items` promotes the surviving row to
  `verified: true` if either side was verified; `game_companies` ORs `developer`/`publisher`
  rather than letting one row's flags overwrite the other's (see below).

`category_items` is a variant of repoint-or-drop that copies rather than moves: the target gets a
`find_or_create_by(category_id:)` and the source's own row simply dies with it, since a
`CategoryItem` carries no state worth preserving beyond the link itself.

## Transaction boundary

One `ActiveRecord::Base.transaction` wraps: collecting the affected ranking configurations (for
mergers whose rankings derive from lists — games, and the planned books merger; the author merger
has no such step, see "Author-specific rules" below), every association move, scalar
reconciliation, `target.save!`, and `source.destroy!`. Reindexing the
target and scheduling ranking jobs both happen **after** that transaction commits, never inside
it — `perform_async`/`perform_in` write to Redis immediately, and a transaction rollback cannot
undo a Redis write. A job scheduled inside the transaction and then rolled back would wake up
describing a merge that never happened.

This ordering is also why `#collect_affected_ranking_configurations` runs first, before any
association is touched: `source.destroy!` cascades and deletes the source's own `ranked_items`, so
once that happens there is no way to recover which ranking configurations the source used to
belong to. The set has to be captured before the transaction does anything else.

Unindexing the source is automatic and needs no code here — `SearchIndexable`'s own
`after_commit :queue_for_unindexing` fires when `source.destroy!` commits. The target's own
reindex is not automatic in the same way (nothing guarantees `target.save!` runs, or that it's
enough — a merge changes what's *linked* to the target, like companies and categories, without
necessarily changing an attribute on the target row itself), so the merger queues it explicitly.
That queuing checks `Services::BooksMigration.search_indexing_suppressed?` first, matching what
`SearchIndexable`'s own callbacks already do — the intent is to stay silent during a bulk
migration, not to add index requests `SearchIndexable` itself would have suppressed.

### `success?` means "the merge committed" — not "reindexing and ranking also succeeded"

Reindexing the target and scheduling ranking jobs are real, fallible I/O — `SearchIndexRequest.create!`
hits the database, and `perform_async`/`perform_in` write to Redis — running after the transaction
has already committed. If either raises (a Redis blip, a database hiccup), the merge itself is not
undone: it can't be, the transaction is already closed, the source is already destroyed. Reporting
that as a failed merge would be actively misleading — an admin would see "Failed to merge games"
about a merge that in fact happened, and a retry would then fail with "Game not found" because the
source no longer exists.

So `#run_post_commit_steps` wraps both calls in their own rescue, separate from `#call`'s own
rescue ladder (which still guards the transaction itself, and is unchanged). A post-commit failure
is logged via `Rails.logger.error` and recorded in `stats[:post_commit_error]`; it does **not**
flip `success?` to `false` or populate `errors`. This is a deliberate divergence from the three
music mergers, which have no equivalent guard today: `reindex_target_album`/`reindex_target_artist`
and `schedule_ranking_recalculation` in `Music::{Album,Artist,Song}::Merger` already do real I/O
(`SearchIndexRequest.create!`, `perform_async`/`perform_in`) inside `call`'s own rescue ladder, so a
Redis or database blip there reports `success?: false` for a merge that already committed — the
same failure mode this games merger closes. That defect is live in music today; fixing it is a known
follow-up, deliberately out of scope here — this branch scoped music to the authorization change
only (see "Merge requires delete permission" in the design doc).

## Games-specific rules

- **`developer`/`publisher` are OR'd, not overwritten**, when both games share a company. A
  source row marking a company as publisher-only carries information the target's row may not
  have; ORing keeps both flags instead of letting the target's row silently win.
- **`child_games` must be repointed**, not left alone. The association is `dependent: :nullify`,
  so if the merger did nothing, destroying the source would nullify every one of its children's
  `parent_game_id` and orphan the whole subtree. Repointing them onto the target keeps the
  subtree intact.
- **A target that is itself a child of the source is nullified, not self-parented.** If the
  target's `parent_game_id` pointed at the source, repointing it "to the target" would make the
  target its own parent — a cycle. The merger detects this case and clears the target's
  `parent_game_id` instead.

## Author-specific rules

- **Books are reindexed explicitly, and the ids are collected before any write.** A book's search
  document embeds `author_names` and `author_ids`, so every book the duplicate authored changes
  when its authorship moves. `Books::Author#queue_books_for_reindexing` cannot do this job: it
  fires only on a *name* change, and only over the source's books, which are about to be
  reassigned. The merger captures `source.book_ids` before repointing anything and bulk-inserts a
  `SearchIndexRequest` per book after the transaction commits, in batches of 1,000 to stay well
  under PostgreSQL's bind-parameter cap. Books whose duplicate link was *dropped* are in that set
  too — they used to carry both authors and now carry one.
- **`book_authors` move with `delete_all` + `update_all`, not per-record saves.** Colliding rows
  are deleted via a subquery first, then the rest are repointed in one statement. Both bulk
  operations skip `Books::BookAuthor`'s own `after_commit` reindex hook, which is the point: the
  merger owns the fan-out and does it once per book rather than once per link.
- **Ranking recalculation is one argument-less job.** Books and games schedule
  `BulkCalculateWeightsJob` + `CalculateRankingsJob` per affected ranking configuration, because
  their rankings derive from lists. Author rankings derive from *book* rankings, so an author merge
  fires `Books::CalculateAuthorRankingsJob.perform_async`, which resolves
  `Books::Authors::RankingConfiguration.default_primary` itself. There is consequently no
  `collect_affected_ranking_configurations` step in this merger, and no ordering constraint about
  running it first. (The converse also holds: a *book* merge gets author recalculation for free,
  because `CalculateRankingsJob` already cascades into that job.)
- **`credits` are deduped by the merger or not at all.** `books_credits` has no unique index, so
  the `(creditable_type, creditable_id, role)` key is enforced in application code. Two rows
  crediting the same person as translator of the same edition is exactly the duplicate a merge
  should remove, and nothing downstream would reject it.
- **Relationships are dropped in two cases, in both directions.** A relationship pointing at the
  survivor would become a self-relation, which `Books::AuthorRelationship`'s `no_self_reference`
  validation rejects — and since that raise happens inside the transaction, leaving it in place
  would roll the entire merge back. One the survivor already holds would violate the
  `(from_author_id, to_author_id, relation_type)` unique index. Direction is meaningful, so a
  surviving relationship in one direction is never treated as a duplicate of one in the other.
- **Authors are not listable.** There is no `list_items` or `user_list_items` on `Books::Author`,
  so the personal-saved-list caveat in the games modal has no author equivalent and is absent from
  the author modal by design, not by omission.

## Scalar reconciliation

The target's own non-blank values always win — there is no field-level "pick a winner" UI.
Reconciliation only fills in what's missing:

- **Blank-fill**: `description` and `series_id` are copied from the source only if the target's
  own value is blank.
- **Earliest wins**: `release_year` takes the lower of the two games' years, if the source has one
  at all.
- **`parent_game_id`** is filled from the source only when the target's own is blank, the target
  is not itself a `main_game` (a main game can't have a parent at all), and doing so wouldn't
  create a cycle back through the target's own ancestry.

For authors the blank-filled fields are `sort_name`, `birth_year`, `death_year`, `gender` and
`description`. `kind` and `exclude_from_rankings` are deliberately excluded: `kind` is NOT NULL
with a default so it is never blank (and folding a pseudonym into a person must not turn the
person into a pseudonym), and `exclude_from_rankings` is a NOT NULL boolean defaulting to false —
`false.present?` is `false`, so blank-filling it would let a duplicate's `true` silently drop the
survivor out of the rankings.

Authors also **absorb names**: the duplicate's `name` and its own `alternate_names` are added to
the survivor's `alternate_names`, deduped, with the survivor's own name never listed among them.
This is often the point of the merge — folding "J.R.R. Tolkien" into "J. R. R. Tolkien" should
leave the deleted spelling findable. `alternate_names` is GIN-indexed and feeds `as_indexed_json`,
so the survivor's post-commit reindex picks it up.

Games have no `alternate_titles` column, so unlike authors above, and unlike the design's plan for
books, there is no name absorption here.

## Testing

`test/lib/games/game/merger_test.rb` mirrors the shape of the music merger tests: fixture
`ranked_items` are cleared in `setup` for the games under test (the fixture file has a row for
every game, and Sidekiq runs inline in tests, so leaving them in place would schedule real jobs).
Every repoint-or-{drop,merge} rule is tested on both branches — the source's row moving across,
and the source's row being dropped or merged because the target already had the colliding value —
since testing only the transfer branch is how this kind of rule silently degrades into a plain
repoint and starts raising `RecordNotUnique` in production.

`test/lib/books/author/merger_test.rb` follows the same shape with two additions specific to
authors. `Books::CalculateAuthorRankingsJob.perform_async` is stubbed in `setup`: Sidekiq runs
inline in tests and the author merger fires that job unconditionally, so an unstubbed merge would
run a real ranking calculation in every test. And the two reindex tests call a
`neutralize_scalar_confound` helper first — scalar reconciliation nearly always dirties the target
(absorbing the duplicate's name alone does it), and the resulting `target.save!` fires
`SearchIndexable`'s own `after_commit`, creating exactly the `index_item` row those tests mean to
attribute to the merger's explicit reindex. Without the helper they pass against a merger that
does no reindexing at all.

## Related documentation

- `docs/superpowers/specs/2026-08-23-record-merge-design.md` — the full three-domain design:
  per-association tables for the `Books::Book` merger (not yet built) and the `Books::Author`
  merger, the reasoning behind each departure from the music pattern, and the increment breakdown.
- `app/lib/music/album/merger.rb`, `app/lib/music/artist/merger.rb`, `app/lib/music/song/merger.rb`
  — the prior art this pattern is ported from.
