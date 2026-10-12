# Books subjects and locations

How the books `subject` and `location` categories are named, organised, merged and cleaned up.
Genres are separate and not covered here. Design: `docs/superpowers/specs/2026-10-11-books-category-cleanup-design.md`.
Measurements: `docs/data-quality/books-categories.md`.

## What subjects and locations are for

Browse and landing pages come first ("The greatest books on War", "Set in Paris"). Similarity and
recommendations come a close second. So every browse-worthy category needs one clean name, and
specific tags that only help similarity are kept rather than pruned.

## Naming rules

These are also in the AI prompts.

Both types:

- Title Case, Chicago style (minor words lowercase unless first): `Death and Grief`, `Women in Science`.
- `and`, not `&`. Straight ASCII apostrophes and hyphens.
- No trailing punctuation, no surrounding whitespace, no unbalanced brackets.

Subjects:

- A noun or noun phrase naming a topic or theme. Not a genre (`Science Fiction`), not a location, not a format (`Anthology`).
- Don't rename just to change singular to plural. Merge only when both forms exist, into the more-used one.

Locations:

- The common English name, current if the place still exists: `Kolkata` (alias `Calcutta`), `Gdańsk` (alias `Danzig`). Historical states keep their historical name: `Soviet Union`, `Roman Empire`.
- No containing place in the name: `Paris`, not `Paris, France`. The hierarchy carries that.
- When two places share a name, the more-linked one keeps the bare name and the other gets a parenthetical qualifier: `Georgia` and `Georgia (U.S. state)`. Qualifiers are the only legitimate brackets.
- Old names and spellings go in `alternative_names`.

## The location tree

Locations form a single-parent tree on `categories.parent_id`. Subjects stay flat.
`Books::Category#ancestors` walks the parents, nearest first, capped at `MAX_DEPTH` (8) levels so a
cycle written outside validation cannot loop. A validation requires the parent to be a books
location, and not the category itself or one of its descendants.

- Shape: continent or region, country, state or province, city, neighbourhood or landmark. Levels may be skipped (`Kilwa` under Tanzania under Africa).
- Roots are the continents, `Fictional Location`, regions that span continents (`Middle East`, `Arctic`) and a few global places (`Outer Space`, `Atlantic Ocean`). The AI may propose another root; the cleanup report lists every one.
- A country's parent is always its continent. Named regions inside one continent (`Caribbean`) sit under that continent, but countries do not nest under them. A transcontinental country goes under the continent with most of its population.
- Historical cities and sites go under the modern country (`Troy` under Turkey). Historical states and empires go under their continent and are not merged into modern countries.
- Invented worlds and their places go under `Fictional Location`. An invented place in the real world gets its real parent.

## Link sources

`category_items.source` records why a link exists directly: `legacy` (0, from the old site and the
weekly sync), `admin` (1, added in the admin), `inherited` (2). A row is `inherited` only because a
descendant location is linked to the same book. A later direct link upgrades the row to its source;
it never goes the other way.

`Categories::AncestorReconciler.call(item_ids: nil)` keeps inherited rows right: it adds a missing
inherited link for every ancestor of a direct location link, deletes inherited links no direct
descendant still needs, recomputes `item_count` and queues reindexes. It is idempotent. Callers: the
admin add and remove category actions, `Categories::Merger` and `Categories::Deleter`, the book
merger, the weekly sync (`location_ancestors` step), cleanup apply, the location trim, and an admin
re-parent. `bin/rails categories:reconcile_ancestors` runs it for every book.

The book page shows only direct (non-inherited) location links, each as a trail of links running up
to but not including the root (`Chicago, Illinois`). `Books::LocationTrails` builds them with one
query. Subjects render as before.

## Merging and renaming

- `categories.merged_into_id` points at the merge target. A merged category is also `deleted: true`. The merger flattens on write, so lookups never follow a chain.
- `Category#canonical` returns the category itself if active, the target if merged, `nil` if deleted without a merge. `Category.replace_merged_ids(ids)` swaps merged ids for their targets.
- `Categories::Merger` runs in one transaction: bulk-copies links with `ON CONFLICT DO NOTHING` (keeping `source`), appends the source name and its alternative names to the target's `alternative_names`, moves child categories, recomputes counts once and queues one reindex. It allows different `category_type` within the same STI type, and refuses a different STI type, a merge into itself or a descendant, and the four book-type categories (Fiction, Nonfiction, Poetry, Religion and Spirituality). `Deleter` and the admin destroy action refuse those four too.
- Category slugs use friendly_id history, backfilled by migration so every existing category has a history row.
- `Books::CategorySlugResolver` turns an old slug (merged or renamed) into the live category. `Books::FilterParams` and the legacy `/genres/:id` route use it: an old filter URL answers 301 to the canonical path with other segments kept, and a slug that resolves to nothing still 404s.
- Saved searches and recommendation settings store category ids. They resolve merged ids through `replace_merged_ids` at query time and in their labels; stored ids are not rewritten.
- The weekly sync links a new legacy item to the merge target. A link to a category deleted without a merge is still dropped.
- Admin: the category page has a merge form (target picked by autocomplete, plus a confirm checkbox; needs destroy permission). Alternative names are edited one per line, because names such as "Oakland, California" contain commas.

## Browse threshold and alias search

`config.x.books.browse_min_category_books` (5): subject and location categories with fewer ranked
books are left out of browse listings and the public filter modal's category search. Their pages
still render, since book-page links point at them. Genres are exempt. Category search also matches
`alternative_names`, so `Calcutta` finds `Kolkata`.

The saved-search category picker has no threshold. That is deliberate.

## The cleanup runbook

Every `propose` stage is resumable: it only processes categories with no decision in that run. Run
these from `web-app/`, with `RUN` a label such as `2026-10-15-prod`.

1. Snapshot: `bin/snapshot-dev-db.sh --label pre-category-cleanup` in dev, a fresh backup in production.
2. `bin/rails 'categories:cleanup:propose[RUN,rules]'`. No AI. Case and punctuation twins merge into the most-linked member (one that already holds the clean name wins a tie). Broken names are repaired, and letterless bracket fragments (`61)`) are deleted. Empty categories are never deleted, because the weekly sync brings categories before their books and a link to a deleted category is lost for good. Legacy alternative names never drive a merge. `C`, `C++` and `C#` stay apart.
3. `bin/rails 'categories:cleanup:propose[RUN,locations_head]'`, then `subjects_head`. Head means a category's own direct link count is at least `head_min_links` (20), one category per AI call. A head category whose call failed is retried by running the head stage again.
4. `bin/rails 'categories:cleanup:calibrate[RUN,location]'` and `[RUN,subject]`. It writes no decisions. It compares batch sizes against one-at-a-time answers on 200 random tail categories. Set `tail_batch_size` to the largest size with at least 97% agreement, or leave it at 1.
5. `bin/rails 'categories:cleanup:propose[RUN,locations_tail]'`, then `subjects_tail`. Tail runs print how many head-tier categories are still undecided.
6. `bin/rails 'categories:cleanup:report[RUN]'`. It prints counts by stage, action and status; undecided head-tier categories; the largest merges; merges into a category with its own pending terminal decision; locations apply would create (with their slugs); proposed roots; ambiguous names; failures; and samples per action. The full list goes to a CSV in `tmp/`.
7. `bin/rails 'categories:cleanup:reject[RUN,"12 15 19"]'` for decisions you do not want. Rejected decisions are kept and skipped.
8. `bin/rails 'categories:cleanup:apply[RUN]'`. Details below.
9. `DRY_RUN=1 bin/rails 'categories:trim_locations[100]'` and read the output, then the same without `DRY_RUN`. Details below.
10. Propose again for categories the first pass retyped: `propose[RUN2,locations_head]` and `locations_tail` pick up subjects retyped into locations, and the subject stages pick up locations retyped into subjects. A new run label is fine.
11. After this the weekly sync keeps new legacy categories in line (last paragraph below).

Switches, as environment variables on `propose`: `LIMIT=n` caps the calls in a stage. `REDO=1` deletes
that stage's `proposed` and `failed` decisions before running, inside the same transaction as the
cost guard, so an over-limit refusal rolls the delete back. `FORCE=1` lets a stage exceed the cost
limit (about $50 estimated). `propose` prints the estimate before it starts and a progress line every
100 calls. `FORCE=1` on `trim_locations` re-trims books that already have a ledger row.

What apply does:

- Before anything it checks each decision's category against its snapshot. A changed category is marked `stale` and skipped. A conflict pre-pass also marks a rename, set-parent or keep stale ("superseded by ...") when a terminal merge, retype or delete exists for the same category.
- Parents named in a chain that match no category are created in one transaction. If a created parent's slug collides, it gets a UUID suffix and the report flags it.
- A rename keeps the old name in `alternative_names` and the old slug in history.
- Reconcile (`AncestorReconciler`) runs whenever the run applied any decision, followed by one reindex pass. Each decision is its own transaction, so one failure marks that decision `failed` and the rest continue. Re-running is a no-op for applied decisions.

What the trim does: a book with more than `max_direct_locations` (15) direct locations gets one AI
call and keeps the subset the model returns. Only `legacy` links are removed. Admin links are never
removed; the model sees them as fixed. The prompt carries each location's full parent chain. Two
guards: an answer that contains none of the offered ids fails, and an empty keep on a book not
marked Nonfiction is skipped as "needs review". Both write a `skipped` ledger row (kind
`books.location_trim`), which is the review queue; `FORCE=1` retries those books. Plain AI failures
and dry runs write nothing. A real trim writes a ledger row with the kept and removed ids, so a book
is not trimmed twice unless forced.

After the first cleanup is applied, `data_migration:sync` runs a `category_cleanup` step: the rules
pass over categories no run has decided, with the rule decisions applied at once (AI decisions are
never auto-applied). Categories whose only decisions failed or went stale are retried each week.
Anything else waits for your next `propose`.

## Configuration

`config/initializers/categories.rb`:

- `config.x.books.browse_min_category_books` (5): the browse and filter-search threshold.
- `config.x.categories_cleanup.head_min_links` (20): direct links needed to be head tier.
- `tail_batch_size` (1): tail categories per AI call; set from calibration.
- `max_direct_locations` (15): books above this get the trim.
- `sample_titles` (5): sample books shown to the model per category.
- `estimated_cost_per_call` and `max_unforced_cost` ($50): the estimate and the limit above which `propose` needs `FORCE=1`. Re-check the price before a production run.
