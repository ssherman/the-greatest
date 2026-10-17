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
- A city and an administrative unit covering the same place are one place: `Berlin (state)`, `Tokyo Metropolis`, `District of Columbia` and `Greater London` merge into their cities and never sit above them. Apply also skips a chain name that resolves to the place itself and takes the next.

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

The book page shows only direct (non-inherited) location links, each as a trail: the location with its ancestors up to, but not including, the root (a continent, a cross-continent region, Fictional Location or a global place), so `Chicago, Illinois, United States`. A link to a root itself shows the root. `Books::LocationTrails` builds them with one
query per tree level. Subjects render as before.

## Merging and renaming

- `categories.merged_into_id` points at the merge target. A merged category is also `deleted: true`. The merger flattens on write, so lookups never follow a chain.
- `Category#canonical` returns the category itself if active, the target if merged, `nil` if deleted without a merge. `Category.replace_merged_ids(ids)` swaps merged ids for their targets.
- `Categories::Merger` runs in one transaction: bulk-moves links with `ON CONFLICT DO UPDATE`, which keeps `source` and upgrades the target's inherited row to the incoming direct source (never downgrades), appends the source name and its alternative names to the target's `alternative_names`, moves child categories, recomputes counts once and queues one reindex. It allows different `category_type` within the same STI type, and refuses a different STI type, a merge into itself or a descendant, and the four book-type categories (Fiction, Nonfiction, Poetry, Religion and Spirituality). `Deleter` and the admin destroy action refuse those four too.
- Category slugs use friendly_id history, backfilled by migration so every existing category has a history row.
- `Books::CategorySlugResolver` turns an old slug (merged or renamed) into the live category. `Books::FilterParams` and the legacy `/genres/:id` route use it: an old filter URL answers 301 to the canonical path with other segments kept, and a slug that resolves to nothing still 404s.
- Saved searches and recommendation settings store category ids. They resolve merged ids through `replace_merged_ids` at query time and in their labels; stored ids are not rewritten.
- The weekly sync links a new legacy item to the merge target. A link to a category deleted without a merge is still dropped.
- Admin: the category page has a merge form (target picked by autocomplete, plus a confirm checkbox; needs destroy permission). Alternative names are edited one per line, because names such as "Oakland, California" contain commas.

## Browse threshold and alias search

`config.x.books.browse_min_category_books` (5): subject and location categories are left out of
browse listings when they have fewer ranked books, and out of the public filter modal's category
search when `categories.item_count` (all catalog links, ranked or not) is below it. Their pages
still render, since book-page links point at them. Genres are exempt. Category search also matches
`alternative_names`, so `Calcutta` finds `Kolkata`.

The saved-search category picker has no threshold. That is deliberate.

## Category index page

`/categories` is the public index of browsable categories. Design:
`docs/superpowers/specs/2026-10-17-books-categories-page-design.md`.

URLs:

- `/categories` is genres, `/categories/settings` and `/categories/subjects` the other two types. The enum stays `genre` / `location` / `subject`; `Books::BrowsePath` is the one place that maps the type to the URL word.
- `…/sorted-by/name` is A to Z (most books is the default and has no segment). `…/page/N` paginates, 120 per page.
- Sort and page segments are regex-constrained in the routes. That is load-bearing: the query object falls back to the default for any input, so an open segment would mint endless soft-duplicate URLs. A sorted variant is `noindex, follow` and canonicalizes to the unsorted path.
- Old `/genres` index URLs (`/genres`, `/genres/filtered-by/<type>`, `/genres/sorted-by/…`, `…/page/N`, and the `?filter=&sort=&page=` forms) answer a single 301 to the matching `/categories` URL. A redirect that went through an intermediate URL would hand crawlers two hops. `/genres/:id` is unchanged and still 301s to `/the-greatest/<slug>/books`; it must stay declared after the redirect.
- `/countries` shares the toolbar and card components and gets the sort dropdown, but no tabs, search or chains.

The page: type tabs, a sort dropdown, a search box and a grid of cards. The tabs are page links in a
labelled `nav` (`aria-label="Category type"`) with `aria-current` on the active one, not ARIA tabs:
there are no panels to switch. The sort options are plain links so every order keeps a cacheable URL.
The details menu is closed before Turbo snapshots the page, otherwise Back would restore it open.

Ranked-count invariant: the grid and the search share `Books::BrowseQuery.ranked_scope`. Both gate
on, and display, the count of ranked books in the primary ranking (not `categories.item_count`,
which counts the whole catalog), with the per-type minimum above. A card therefore never links to an
empty page, and a search hit never disagrees with the grid.

Chains: a child location shows its ancestors, root first, as a muted line under the name
(`Europe › France`). `Books::CategoryChains` loads the chains for a whole page with one recursive
query; calling `Category#ancestors` per card would be hundreds of queries on a 120-card page.
Top-level categories and all subjects show no chain.

Search (`/categories/search?q=&filter=`):

- Covers all three types, so a reader looking for "War" does not have to know which tab it lives on. Each result carries a type badge ("Genre", "Setting", "Subject"). Results are capped at 60, with no pagination, and require at least two characters.
- A match is a case-insensitive substring of the name or an alternative name (the same condition as `CategorySearchQuery`).
- Ordering is match quality first: name equals the query, then name starts with it, then a word in the name starts with it, then name contains it, then alias-only. The current tab's type is the tiebreaker within a quality, then ranked count, then name. Type-first was tried and rejected: past merges left junk alternative names (Europe carries "World War I Europe"), so an alias-only hit on the current tab outranked the category literally named "War".
- Searching runs from the page's form, which targets the `categories_results` Turbo frame (frame `target: "_top"`, so result links leave the frame; the form carries its own `data-turbo-frame`). The `books--category-search` Stimulus controller submits 250 ms after typing stops, from two characters up. The URL does not change. One character leaves whatever is showing alone. Clearing the box after a search loads the grid page into the frame again, and the controller cancels an in-flight search or restore so a slow response cannot land late and put results back under an empty box.
- Back restores Turbo's snapshot with the typed text and the results still showing; the controller reads the box on connect so clearing it afterwards still restores the grid.
- Without JavaScript, Enter loads the same endpoint as a full page, which also shows the tabs but no sort menu.
- Accessibility: the status line ("N categories match “war”") is plain text inside the frame, and the controller copies it into a `role="status"` region outside the frame. A live region inserted already holding its text is not reliably announced, and every swap inserts a new one.

Caching: every grid view is `cache_for_index_page` (public, 6 hours at the edge) and renders identical
HTML for every visitor. The search endpoint is the opposite: `prevent_caching`, `noindex`, and
excluded from the canonical-redirect filter, because free-text queries are not worth caching and are
hit on every pause in typing.

Tests: `test/controllers/books/browse_controller_test.rb`, `test/lib/books/browse_query_test.rb`,
the routing and component tests beside them, and the Playwright spec
`web-app/e2e/tests/books/browse.spec.ts`.

## The cleanup runbook

Every `propose` stage is resumable. The rules stage rebuilds its own proposed decisions each time. An AI stage skips categories already decided in that type's head or tail stages of the run (a category whose only decision is a rules rename is still sent; rules merges and deletes remove a category from the AI stages). Run
these from `web-app/`, with `RUN` a label such as `2026-10-15-prod`.

1. Snapshot: `bin/snapshot-dev-db.sh --label pre-category-cleanup` in dev, a fresh backup in production.
2. `bin/rails 'categories:cleanup:propose[RUN,rules]'`. No AI. Case and punctuation twins merge into the most-linked member, except that when that member would need a rename, the member already holding the clean name wins outright. Broken names are repaired, and letterless bracket fragments (`61)`) are deleted. Empty categories are never deleted, because the weekly sync brings categories before their books and a link to a deleted category is lost for good. Legacy alternative names never drive a merge. `C`, `C++` and `C#` stay apart.
3. `bin/rails 'categories:cleanup:propose[RUN,locations_head]'`, then `subjects_head`. Head means a category's own direct link count is at least `head_min_links` (20), one category per AI call. A head category whose call failed is retried by running the head stage again.
4. `bin/rails 'categories:cleanup:calibrate[RUN,location]'` and `[RUN,subject]`. It writes no decisions. It compares batch sizes against one-at-a-time answers on 200 random tail categories, and prints a baseline first: a second one-at-a-time pass against the first. One-at-a-time answers are not stable (86.5% of locations and 88.5% of subjects agreed in the 2026-10-12 dev run), so judge each batch size against that baseline, on both the full agreement and the action/verdict agreement, not against 100%. A size that agrees about as well as the baseline loses nothing to batching. `tail_batch_size` is set per type (`{location: 10, subject: 1}` from that run); changing it means editing `config/initializers/categories.rb` and deploying (merge = deploy).
5. `bin/rails 'categories:cleanup:propose[RUN,locations_tail]'`, then `subjects_tail`. Tail runs print how many head-tier categories are still undecided. At batch size 1 `subjects_tail` exceeds the $50 guard (about $165 at current estimates) and needs `FORCE=1`; `locations_tail` at 10 is about 1,540 calls.
6. `bin/rails 'categories:cleanup:report[RUN]'`. It prints counts by stage, action and status; undecided head-tier categories; the largest merges; the largest deletes (a junk verdict on a big category shows here); merges into a category with its own pending terminal decision; locations apply would create (with their slugs); proposed roots; ambiguous names; failures; and samples per action. The full list goes to a CSV in `tmp/`.
7. `bin/rails 'categories:cleanup:reject[RUN,12 15 19]'` for decisions you do not want. Rejected decisions are kept and skipped.
8. `bin/rails 'categories:cleanup:apply[RUN]'`. Details below.
9. Propose again with the SAME run label: `propose[RUN,locations_head]`, `locations_tail`, `subjects_head` and `subjects_tail`. Then review as in steps 6 and 7 (`report[RUN]`, `reject`), and only then `apply[RUN]` again. Only categories with no decision in those stages yet are sent: ones retyped by the first apply (subjects now locations and the reverse), created parents, and categories the sync added. A new label would re-send the whole vocabulary and apply a second full wave, so do not use one. This second wave runs before the trim because it can add direct location links (merges of `is_location` categories, retyped subjects), and the trim prompt should see the full hierarchy.
10. `DRY_RUN=1 bin/rails 'categories:trim_locations[100]'` and read the output, then the same without `DRY_RUN`, and repeat the real run until it prints nothing (no candidates left) or only `FAILED` lines (AI failures write no ledger row and are retried on every run). The limit can be raised once the first batch looks right. The dry run's answers are a sample: the real run makes fresh AI calls. Details below.
11. After this the weekly sync keeps new legacy categories in line (last paragraph below).

Switches, as environment variables on `propose`: `LIMIT=n` caps the number of categories sent in a stage (the same as calls only at batch size 1). `REDO=1` deletes
that stage's `proposed` and `failed` decisions before running, inside the same transaction as the
cost guard, so an over-limit refusal rolls the delete back. `FORCE=1` lets a stage exceed the cost
limit (about $50 estimated). `propose` prints the estimate before it starts and a progress line every
100 calls. For example `FORCE=1 bin/rails 'categories:cleanup:propose[RUN,locations_tail]'`. `FORCE=1` on `trim_locations` re-trims books that already have a ledger row.

What apply does:

- Before anything it checks each decision's category against its snapshot. A changed category is marked `stale` and skipped. A conflict pre-pass also marks a rename, set-parent or keep stale ("superseded by ...") when a terminal merge, retype or delete exists for the same category (a rename that accompanies a retype is kept: renames run first). If a category has several terminal decisions, the first by phase (merge, retype, delete) wins and the others go stale too.
- Head categories are decided one per call, so the AI can propose A into B and B into A (`Gods` and `Deities`). Before anything applies, every merge cycle is broken at its most-linked member (`item_count`, ties to the older category): its merge goes stale ("merge cycle"), so it stays, keeping any rename, and the rest of the cycle merges into it. A member that also has a proposed retype or delete is never chosen, since its delete would then remove the links merged into it; if every member has one, the cycle is left alone (one merge lands, the reverse fails).
- Parents named in a chain that match no category are created in one transaction. If a created parent's slug collides, it gets a UUID suffix and the report flags it.
- A rename keeps the old slug in history. It keeps the old name in `alternative_names` only when it differs from the new name by more than case or punctuation and is not already listed.
- Reconcile (`AncestorReconciler`) runs whenever the run applied any decision. The reconciler and the Merger queue their own reindexes. Each decision is its own transaction, so one failure marks that decision `failed` and the rest continue. Re-running is a no-op for applied decisions. A decision that went stale (its category changed before apply) is not re-sent under the same RUN; such a category needs an admin fix or a `REDO=1` of that stage.

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
- `tail_batch_size` (`{location: 10, subject: 1}`): tail categories per AI call, by type; set from calibration.
- `max_direct_locations` (15): books above this get the trim.
- `sample_titles` (5): sample books shown to the model per category.
- `estimated_cost_per_call` and `max_unforced_cost` ($50): the estimate and the limit above which `propose` needs `FORCE=1`. Re-check the price before a production run.
