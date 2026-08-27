# Ranked Users' Lists — Design

Date: 2026-08-27
Status: Approved, ready for implementation planning
Scope: Books, Music::Albums, Music::Songs, Games. Books is the priority; the other three
ship switched off until their data justifies activation.

## Summary

Every night, aggregate every user's *favorites* list for a domain into a single generated
`List` — "Our Users' Favorite Books of All Time" and its equivalents — which then feeds the
normal ranking engine like any other list.

This replaces the legacy `GenerateRankedUsersList`, which had three defects: it let a handful
of heavy users dominate the vote, it read insertion order as if it were a preference ranking,
and it fired a full recomputation on every single favorite click.

## Background: the legacy implementation

`the-greatest-books/admin/app/lib/generate_ranked_users_list.rb`. For every `UserList` of
type `favorite`, each book scores `N − position + 1` where N is the list's length. Scores sum
across all users, then split into two `List` records: the top 100, and an "honorable mention"
holding everything from 101 down. Both are refreshed and the whole book ranking recalculated.

It was triggered from `UserListBook` `after_create`, `after_destroy` and `after_update`.

### Defect 1: unbounded per-user influence

Because each book scores `N − position + 1`, a list of N contributes `N(N+1)/2` points in
total. A 558-book list therefore contributes 155,961 points; a 5-book list contributes 15.

Measured over the 3,370 non-empty books favorites lists in dev (31,363 items):

| Favorites list size | Voters | Share of total score |
|---|---|---|
| 1–9 books | 2,505 | 3.1% |
| 10–49 | 781 | 18.8% |
| 50–99 | 58 | 15.2% |
| 100–499 | 25 | 45.0% |
| 500+ | 1 | 17.9% |

**26 people out of 3,370 control 63% of the vote. One person controls 17.9%.**

### Defect 2: position was insertion order, not preference

Comparing each list's position order against its creation order: only **257 of 3,370** lists
(7.6%) are in any order other than "order added" — 215 of 1,692 (12.7%) among lists of 5+.
Legacy treated the remaining ~92% as strict preference rankings.

The timestamps are trustworthy: `user_list_items.created_at` values survived the legacy
migration intact, spread across 2023–2026, with as many distinct timestamps per list as items.
Nothing was bulk-stamped on the migration date.

When users *do* reorder, they do it decisively — of the 215 curated lists with 5+ items, 140
have more than half their items out of insertion order, 71 have 10–50%, and only 4 are under
10%. There is almost no grey zone, so a `mismatches > 0` test is a clean binary signal.

The blind spot: a user who adds books in preference order and never needs to move anything is
indistinguishable from one who appends carelessly. That is undetectable, and it fails safe —
we treat their list as unordered rather than inventing a ranking that is not there.

### Defect 3: recomputation on every click

`GenerateRankedUsersListJob.perform_async` on every favorite add, remove and reorder. On the
legacy site a single user working through their favorites created hundreds of very heavy jobs,
each ranking run taking ~15 minutes. The new app has 3,096,650 `user_list_items` and a queue
that is already a throughput bottleneck.

## How the ranking engine actually treats a list

Measured against the live books configuration (`RankingConfiguration` 8: exponent 3.0,
bonus_pool_percentage 3.0, `median_list_count` 50) for a list at weight 40:

| List length | #1 | #10 | last | #1 vs last | List's total score mass |
|---|---|---|---|---|---|
| 50 | 49.2 | 45.1 | 40.0 | 1.23× | 2,120 |
| 100 | 49.4 | 47.1 | 40.0 | 1.24× | 4,240 |
| 250 | 49.5 | 48.5 | 40.0 | 1.24× | 10,600 |
| 6,933 | 49.6 | 49.6 | 40.0 | 1.24× | 293,959 |

Two facts drive the whole design:

1. **Being on a list is what counts.** Position adds at most 24%, at any length. This is
   structural: with exponent `e`, the top item's share of the bonus pool is ≈ `(e+1)/L`, while
   the pool itself scales by `L / average_list_length` — the `L` cancels.
2. **A list's influence scales linearly with its length.** This is why the imported 6,933-item
   honorable mention had to be penalised to weight 0. At weight 40 it would have handed 40
   points to nearly 7,000 books, when the 500th-ranked book in the entire system scores 390.

A 250-item list at weight 40 is *not* dominant, contrary to a first draft of this analysis
which benchmarked against median list *length* (50) rather than median *contribution* (497).
Measured properly across the 622 active books lists:

| Users' list | Score mass | Share of all books score | Rank of 623 |
|---|---|---|---|
| 100 books @ weight 40 | 4,240 | 0.2% | #116 |
| **250 books @ weight 40** | **10,600** | **0.6%** | **#26** |
| 500 books @ weight 40 | 21,200 | 1.2% | #9 |

The real heavyweights: *1001 Books You Must Read Before You Die* contributes 95,495 (5.6%,
weight 90 × 1,001 items), *Harenberg Buch der 1000 Bücher* 90,312, *1000 Novels Everyone Must
Read* 84,546, Bloom's *Western Canon* 58,752. A 250-book users' list is nine times smaller
than the largest.

## The scoring model

**A ballot** is one user's favorites list for one domain — a `UserList` subclass with
`list_type: :favorites` holding at least one item. One user, one ballot per domain. All four
participating subclasses already use `favorites: 0`, so the scope is uniform.

**Ballot mass.** Every ballot is worth `√N` points in total, where N is its item count. A
400-book list is worth 20× a 1-book list, not 400×.

**How a ballot spends its mass:**

- `manually_ordered == false` → split evenly; each item gets `√N / N`.
- `manually_ordered == true` → split by position; the item at position *p* gets
  `√N × (N+1−p)^k / Σ(N+1−p)^k`.

The ballot's total is identical either way. Arranging your list changes *where* your influence
lands, never *how much* you get — which is what stops curation becoming a gaming vector once
reordering ships.

**The decay exponent is `k = 2.0`**, held in Rails config, not an admin screen.

k barely affects the outcome — measured on real data, k=1.0 and k=3.0 produce 245 of the same
250 books and 24 of the same top 25. What it changes is what curating does to your own ballot:

| Curated list of 51 | Your #1 | Your #5 | Your #26 | Items beating the flat 1.96% |
|---|---|---|---|---|
| k = 1.0 | 3.85% | 3.54% | 1.96% | 25 of 51 |
| **k = 2.0** | **5.71%** | **4.85%** | **1.48%** | **22 of 51** |
| k = 3.0 | 7.54% | 5.90% | 1.00% | 19 of 51 |

At k=2.0 your top pick carries roughly 3× a flat vote — enough that ordering visibly pays —
while your lower favorites still count. At k=3.0 everything past ~#35 of a 51-book list rounds
to zero, which punishes curating a long list.

**Aggregation.** Sum every ballot's contribution per listable, sort descending, take the **top
250**. An item needs **at least 2 distinct voters** to appear. That floor is inert for books —
2,651 books clear it, the 250th book has 19 voters and the minimum in the cut is 13 — but it
stops one person's obscure pick reaching a public "our users' favorites" page in the thin
domains.

**Cost:** one SQL fetch plus an in-memory pass. Books measures **0.7s** end to end, of which
the aggregation is 43ms and the rest is fetching 31,363 rows.

### Why `√N` and not one-vote-per-user

Alternatives, measured against pure one-person-one-vote on the top 100:

| Ballot mass | 1–9 books | 10–49 | 50–99 | 100–499 | 500+ | Top-100 agreement |
|---|---|---|---|---|---|---|
| legacy `N(N+1)/2` | 3.1% | 18.8% | 15.2% | 45.0% | 17.9% | 72 |
| linear `N` | 28.2% | 45.3% | 12.1% | 12.6% | 1.8% | 88 |
| **sqrt `√N`** | **52.2%** | **38.4%** | **5.5%** | **3.6%** | **0.3%** | **97** |
| log `1+ln N` | 59.4% | 35.2% | 3.5% | 1.8% | 0.1% | 97 |
| equal `1` | 74.3% | 23.2% | 1.7% | 0.7% | 0.0% | 100 |

`√N` lands within 3 books of full equalisation while giving the 26 heaviest users about 5×
per-capita influence — credit for engagement without anyone dominating. `log` is a near-tie;
`√N` is easier to explain.

### Expected output (books, dev data)

Top 25 under the agreed model (`√N` mass, k = 2.0), with distinct voter counts:

| # | Book | Voters | # | Book | Voters |
|---|---|---|---|---|---|
| 1 | Nineteen Eighty Four | 393 | 14 | Dune | 163 |
| 2 | The Lord Of The Rings | 336 | 15 | Lolita | 177 |
| 3 | Crime and Punishment | 332 | 16 | The Count of Monte Cristo | 157 |
| 4 | One Hundred Years of Solitude | 316 | 17 | Don Quixote | 155 |
| 5 | The Great Gatsby | 272 | 18 | Ulysses | 126 |
| 6 | The Brothers Karamazov | 241 | 19 | The Little Prince | 141 |
| 7 | The Catcher in the Rye | 206 | 20 | War and Peace | 159 |
| 8 | To Kill a Mockingbird | 220 | 21 | Jane Eyre | 151 |
| 9 | Pride and Prejudice | 213 | 22 | The Master and Margarita | 135 |
| 10 | Animal Farm | 195 | 23 | Wuthering Heights | 145 |
| 11 | Anna Karenina | 193 | 24 | Catch-22 | 158 |
| 12 | Moby-Dick | 180 | 25 | Blood Meridian | 141 |
| 13 | The Stranger | 172 | | | |

Ulysses at #18 on 126 voters outranking War and Peace on 159 is curated ballots placing it near
the top of their lists — the model working as intended. 257 of the 3,370 ballots score
positionally.

## The generated list

**One `List` per domain, reused rather than recreated.** Books keeps list **463**, which
already has its public URL, its `RankedList` row in configuration 8, weight 40 and the "voters
are not critics, authors, or experts" penalty attached. It is renamed to drop "Top 100" and its
items are rewritten nightly.

`number_of_voters` is set to the **real ballot count** (3,370 for books) rather than the
hardcoded 5,000 it carries now.

**Identity.** Legacy used `find_or_create_by(name:)`, which breaks the moment the list is
renamed. Add a nullable `auto_generated_kind` enum column on `lists` with a partial unique
index on `(type, auto_generated_kind) WHERE auto_generated_kind IS NOT NULL`. An enum rather
than a boolean costs nothing now and does not box out the "linked dynamic lists" idea already
on the todo.

**Hand edits are refused.** The generator owns those rows and rewrites them nightly, so
anything typed into admin is silently destroyed on the next run. `ListItem` gets a validation
rejecting writes when its list is auto-generated, and admin hides the edit affordances. The
generator uses `delete_all` / `insert_all`, which skip validations by design — so the guard
blocks humans without needing an escape hatch for the job.

**New domains start switched off.** Music, songs and games get their list built but created
`unapproved`, so it is visible in admin and contributes nothing until manually activated. No
threshold to guess at, and no garbage on a public page.

### Honorable mention is deleted

Lists **464** (honorable mention, 6,933 items) and **268** (a stale 1,774-item legacy artifact)
are deleted outright. Inbound links may 404; that is accepted.

The cost is close to zero. 2,854 books have 464 as their only active-list appearance, and all
2,854 currently score **exactly 1.00** — the gem's floor — ranked 16,164 to 20,081 of 24,242.
Because the list sits at weight 0 they contribute nothing today. Deleting them removes 2,854
tied-at-minimum entries from the tail of the rankings and moves no book that actually ranks.
Going the other way, only 3 books in the projected top 250 appear on no other active list.

## Code structure

Two objects, split so the interesting logic is testable without touching `lists`:

- **`Services::Lists::UserFavoritesTally`** — pure. Takes a `UserList` subclass, runs one SQL
  fetch, returns an ordered array of `[listable_id, score, voter_count]`. No writes. Ballot
  mass, the curated/flat split and the decay all live here, and so do essentially all the tests.
- **`Services::Lists::GenerateUserFavorites`** — takes a domain, calls the tally, finds or
  creates the `List` by `(type, auto_generated_kind)`, rewrites its items, updates
  `number_of_voters`. Returns the standard `Result` struct.

Domain wiring hangs off the `UserList` subclasses, matching the existing `listable_class` /
`ranking_configuration_class` pattern: `generated_list_class`, `generated_list_name`,
`generated_list_description`. Four participants: `Books::UserList`, `Music::Albums::UserList`,
`Music::Songs::UserList`, `Games::UserList`.

- **`GenerateUserFavoritesListsJob`** (via `bin/rails generate sidekiq:job`) — loops the four
  domains, each in its own `Result`, so one domain failing does not kill the rest. Takes an
  optional domain argument for on-demand runs.

### Bug fixed in passing

`ranked_lists.list_id` has **no foreign key**, and `::List` has **no `has_many :ranked_lists`**
— so `list.destroy` silently orphans the `RankedList` row, and the admin ranked-lists view then
raises on `rl.list.name`. There are currently 0 orphans across 833 rows.

Add `has_many :ranked_lists, dependent: :destroy` to `List`. No migration, and it fixes the
actual bug. The matching FK constraint is deliberately **not** bundled: it is only a safe
migration if production also has zero orphans, which must be checked before merge.

## Scheduling and control

**Nightly cron** in `config/schedule.yml` at 03:00, ahead of the existing 04:00 author-rankings
and 05:00 Stripe entries.

**No automatic ranking recalculation.** Rankings stay on the deliberate
`Actions::Admin::RefreshRankings` trigger they use today, so a night of favoriting can never
silently reshuffle the site.

**Admin action** `Actions::Admin::RegenerateUserFavoritesList`, shaped like `RefreshRankings`,
shown on a list's show page only when it is auto-generated.

## Migrations and cleanup

**Two schema migrations:**

1. `user_lists.manually_ordered` — boolean, `default: false, null: false`. Postgres adds this
   without a table rewrite. Backfilled by raw set-based SQL comparing position order to
   creation order, scoped to `list_type = 0`, so it touches 3,370 books rows rather than
   scanning 3.1M.
2. `lists.auto_generated_kind` — nullable enum plus the partial unique index above.

**Cleanup is a rake task, not a migration.** The books lists exist only in dev, so a schema
migration referencing them would be a no-op in production and dead weight in every test setup.
The task marks 463 auto-generated and renames it, then deletes 464 and 268 — deleting 464's
`RankedList` row explicitly first, since nothing cascades it. It finds lists by name and no-ops
when absent, so it is safe to run anywhere. Music, songs and games need no cleanup; the
generator creates their lists itself.

## Dependency: reordering

Positional scoring reads `user_lists.manually_ordered`. The flag is backfilled for the 257
legacy curated lists by this work, and set going forward by the reorder action — which is
already scoped as Phase B of the user-lists work (`MyListsController` header:
*"Write actions (create/edit/reorder/remove/delete) are Phase B (user-lists-02f)"*).
Reordering is being implemented imminently; Phase B setting the flag is a one-line change on
its side, and nothing here needs rework.

## Testing

The tally carries the real risk, so tests concentrate there:

- An unordered ballot splits evenly; a curated ballot splits by position; both sum to `√N`.
- `√N` mass holds across differing list sizes.
- The 250 cap and the 2-voter floor.
- **The one that matters:** one large ballot cannot outvote many small ones, asserted as a
  numeric comparison rather than a "returns something" check.

Also:

- A job test that one domain failing does not abort the others.
- A `ListItem` test proving a hand edit to an auto-generated list is *rejected*. Write it by
  deleting the guard and watching it go red first — this codebase has repeatedly produced tests
  that passed against deleted implementations.
- A generator test that a second run over changed ballots replaces items rather than
  accumulating.

No new Playwright test. The public list page at `/lists/:id` is an existing flow, and this adds
no new page or user-facing interaction.

## Known consequences

**The list will pick up the western-canon penalty.** The projected top 250 is **91.60% western**
(229 of 250) against a threshold of 90.0%, so it takes the 10-point penalty. It sits only 1.6
points over the line, so its weight could flip by 10 between weight recalculations as reader
tastes shift — worth watching, but not alarming. Not anomalous either: 135 of the first 200
active books lists are already ≥90% western.

**Duplicate book records will be more visible here than on critic lists.** Of the 3 books in
the projected top 250 that appear on no other active list, one is *"Crime And Punishment"* —
capitalised differently from the *"Crime and Punishment"* already at #3. Aggregating thousands
of independent clicks surfaces duplicates that a single curated list would not. Books
record-merge is not started; this is a note, not scope.

**Fewer books will be ranked overall.** Deleting the honorable mention removes 2,854 books from
the rankings, all currently tied at the floor score of 1.00. Accepted.
