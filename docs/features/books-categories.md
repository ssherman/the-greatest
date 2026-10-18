# Books subjects and locations

How the books `subject` and `location` categories are named, organised, merged and cleaned up.
Genres and audiences are covered in "Genre cleanup and audiences" below. Design: `docs/superpowers/specs/2026-10-11-books-category-cleanup-design.md`.
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

- `/categories` is genres, `/categories/audiences`, `/categories/settings` and `/categories/subjects` the other types. The enum values are `genre` / `audience` / `location` / `subject`; `Books::BrowsePath` is the one place that maps the type to the URL word.
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

- Covers every browsable type, so a reader looking for "War" does not have to know which tab it lives on. Each result carries a type badge ("Genre", "Audience", "Setting", "Subject"). Results are capped at 60, with no pagination, and require at least two characters.
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

1. Snapshot: `bin/snapshot-dev-db.sh --label pre-category-cleanup` in dev. In production, dump just the four tables the pipeline writes, on the Postgres server, right before each `apply` (production commands below).
   Then flatten subjects. Subjects have no hierarchy, but the old site gave some a parent (23 in production), and the Merger refuses to merge a category that has children into a non-location, or into its own child: `Indigenous` into `Indigenous People` failed both ways in the 2026-10-15 run. Clear them before the first `propose`, so that every decision's snapshot already shows no parent. Clearing them after proposing marks those subjects' decisions stale.
   `bin/rails runner 'Books::Category.where(category_type: :subject).where.not(parent_id: nil).update_all(parent_id: nil)'`
   The weekly sync copies the legacy parent of a new subject, so a later run may find a few again.
2. `bin/rails 'categories:cleanup:propose[RUN,rules]'`. No AI. Case and punctuation twins merge into the most-linked member, except that when that member would need a rename, the member already holding the clean name wins outright. Broken names are repaired, and letterless bracket fragments (`61)`) are deleted. Empty categories are never deleted, because the weekly sync brings categories before their books and a link to a deleted category is lost for good. Legacy alternative names never drive a merge. `C`, `C++` and `C#` stay apart.
3. `bin/rails 'categories:cleanup:propose[RUN,locations_head]'`, then `subjects_head`. Head means a category's own direct link count is at least `head_min_links` (20), one category per AI call. A head category whose call failed is retried by running the head stage again.
4. `bin/rails 'categories:cleanup:calibrate[RUN,location]'` and `[RUN,subject]`. It writes no decisions. It compares batch sizes against one-at-a-time answers on 200 random tail categories, and prints a baseline first: a second one-at-a-time pass against the first. One-at-a-time answers are not stable (86.5% of locations and 88.5% of subjects agreed in the 2026-10-12 dev run), so judge each batch size against that baseline, on both the full agreement and the action/verdict agreement, not against 100%. A size that agrees about as well as the baseline loses nothing to batching. `tail_batch_size` is set per type (`{location: 10, subject: 1}` from that run); changing it means editing `config/initializers/categories.rb` and deploying (merge = deploy).
5. `bin/rails 'categories:cleanup:propose[RUN,locations_tail]'`, then `subjects_tail`. Tail runs print how many head-tier categories are still undecided. At batch size 1 `subjects_tail` exceeds the $50 guard (about $165 at current estimates) and needs `FORCE=1`; `locations_tail` at 10 is about 1,540 calls.
6. `bin/rails 'categories:cleanup:report[RUN]'`. It prints counts by stage, action and status; undecided head-tier categories; the largest merges; the largest deletes (a junk verdict on a big category shows here); merges into a category with its own pending terminal decision; locations apply would create (with their slugs); proposed roots; ambiguous names; failures; and samples per action. The full list goes to a CSV in `tmp/`. The CSV holds every decision in the run, not just the latest stage, so on the second wave filter it to status `proposed`.
7. `bin/rails 'categories:cleanup:reject[RUN,12 15 19]'` for decisions you do not want. Rejected decisions are kept and skipped.
8. `bin/rails 'categories:cleanup:apply[RUN]'`. Details below.
9. Propose again with the SAME run label: `propose[RUN,locations_head]`, `locations_tail`, `subjects_head` and `subjects_tail`. Then review as in steps 6 and 7 (`report[RUN]`, `reject`), and only then `apply[RUN]` again. Only categories with no decision in those stages yet are sent: ones retyped by the first apply (subjects now locations and the reverse), created parents, and categories the sync added. A new label would re-send the whole vocabulary and apply a second full wave, so do not use one. This second wave runs before the trim because it can add direct location links (merges of `is_location` categories, retyped subjects), and the trim prompt should see the full hierarchy.
   Reject the second wave's subject-to-location retypes. They are locations the first wave retyped to subjects, and the subject pass now sends back. Their location decision was used up in the first wave, so applied they become locations with no parent. In the 2026-10-15 run that was 17 small categories (`West`, `Islands`, `Third World`). Location-to-subject retypes in the second wave are fine, since subjects need no parent.
10. `DRY_RUN=1 bin/rails 'categories:trim_locations[100]'` and read the output, then the same without `DRY_RUN`, and repeat the real run until it prints nothing (no candidates left) or only `FAILED` lines (AI failures write no ledger row and are retried on every run). The limit can be raised once the first batch looks right. The dry run's answers are a sample: the real run makes fresh AI calls. The output prints every removed location, so send it to a file (`> tmp/trim_dry_run.txt 2>&1`). Details below.
11. After this the weekly sync keeps new legacy categories in line (last paragraph below).

Long stages (the subject tail is about 40,800 calls, a day at roughly 2 seconds each) should run detached with a log. A dropped SSH session ends a foreground `docker compose exec`, and a deploy (any merge to main) recreates the container. Either way, run the same command again; every stage resumes.

```bash
docker compose -f docker-compose.prod.yml exec -d web bash -c \
  "FORCE=1 bin/rails 'categories:cleanup:propose[RUN,subjects_tail]' > log/subjects_tail.log 2>&1"
```

Production backup and restore, on the Postgres server. Only these four tables are written, and no other table has a foreign key into them, so they can be restored on their own. Music and games share `categories`, `category_items` and `friendly_id_slugs`, so take the dump right before `apply` to keep the window short:

```bash
COMPOSE=/home/ssherman/apps/the-greatest-books/docker-compose.prod.yml
docker compose -f $COMPOSE exec -T db pg_dump -U postgres -Fc \
  -t categories -t category_items -t friendly_id_slugs -t category_cleanup_decisions the_greatest \
  > /mnt/data1/backups/pre-category-apply-$(date +%Y%m%d%H%M%S).dump
# Restore, only if needed:
docker compose -f $COMPOSE exec -T db psql -U postgres the_greatest \
  -c 'TRUNCATE categories, category_items, category_cleanup_decisions, friendly_id_slugs'
docker compose -f $COMPOSE exec -T db pg_restore -U postgres -d the_greatest --data-only --disable-triggers < FILE
```

A restore needs a reindex afterwards, because apply queues search updates.

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
- Reconcile (`AncestorReconciler`) runs whenever the run applied any decision. The reconciler and the Merger queue their own reindexes. Each decision is its own transaction, so one failure marks that decision `failed` and the rest continue. Re-running is a no-op for applied decisions. A decision that went stale (its category changed before apply) is not re-sent under the same RUN, and `REDO=1` does not help, because it deletes only `proposed` and `failed` decisions. Either fix the category in the admin, or delete its decisions in that stage (a stage skips any category with a decision there, whatever its status) and propose that stage again.
- Expected refusals, which are safe to leave: a set_parent whose chain names the place itself fails at propose time ("parent chain starts at the place itself"; `Folsom Prison` and `Abu Ghraib Prison` in production); a merge, retype or delete of a category that has places under it is refused at apply time rather than orphaning them (`Commonwealth`, `Alice`).

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

## Genre cleanup and audiences

Design: `docs/superpowers/specs/2026-10-17-books-genre-cleanup-design.md`. The genres came from
Goodreads shelves and mix every kind of label, so the cleanup gives each of the 171 live genres one
reviewed fate and adds an `audience` category type. The test throughout: a genre is what the book
is; a subject is what it is about.

### The types

| type | holds |
|---|---|
| genre | form and reader conventions: Mystery, Fantasy, Memoir, Plays, Graphic Novels. About 40 to 60 after the cleanup |
| audience | who the book is for. Exactly three, flat: Children's (about 0 to 8), Middle Grade (8 to 12), Young Adult (12 to 18) |
| subject | topics, time periods, LGBTQ+, real moods and reception labels |
| location | places |

No audience means a general adult readership; nothing is tagged Adult. Audience scores exactly as a
genre does: `Books::Book::SCORING_TYPE_OF` maps it to the genre bucket, so its ids go into
`genre_category_ids` and `similarity_category_count`, and similar books and recommendations treat it
as a genre. There is no separate `audience_category_ids` index field. Everywhere types are shown it
is its own group: the filter modal, `/categories/audiences` (hidden until an audience exists),
page titles, the book page order (genre, audience, subject, location), the CSV export, and the
global canon, whose exclusions accept genre and audience slugs.

### The two files

Both are committed and reviewed in a PR; production makes no AI calls.

- `config/books/genre_plan.yml`: the `genres:` list and the three fixed `audiences:` (each with a
  definition), then `decisions:`, one per live genre keyed by category id. Actions: `keep`
  (optionally `also:`), `rename`, `merge`, `audience`, `subject`, `location`, `delete`, `split`.
  `run:` names the batch of decisions. Edits after a first `apply` need a new `run:`.
- `config/books/genre_split_assignments.csv` (`book_id,category_id,targets`): for each book on a
  `split` genre, which of the split's targets fit it, or every target when the answer was
  `unknown`.

`PLAN=path` and `ASSIGNMENTS=path` point any command at other copies.

### The commands

All are `categories:genres:<name>`, run from `web-app/`, in this order:

1. `draft` (development). One AI call proposes the genre list and notes. Refuses to overwrite a
   plan that has decisions unless `FORCE=1`. Then Shane edits the list.
2. `map` (development). Batches of 30 genres mapped onto the lists. Resumable; a batch whose answer
   names something off the lists fails whole and is retried on the next run.
3. `split_check` (development). One call per 10 books on a split genre, asking which targets fit.
   Resumable by book, `FORCE=1` past the cost guard.
4. `report` (development). Decisions by action with book counts, delete reference counts (saved
   searches plus recommendation settings), and the validator's verdict.
5. `retarget_worldcat` (development). Rewrites `config/worldcat/genre_map.yml` from the plan (see
   `worldcat-data-service.md`). A second run changes nothing.
6. `apply` (production, Shane runs it). Validates, writes the decisions, runs
   `Services::CategoryCleanup::Applier`, then removes applied deletes from saved searches and
   recommendation settings.

### What apply checks

`Services::Books::GenrePlan::Validator` stops everything, writing nothing, when: a live genre has no
decision (the error names it, which means the plan is out of date); a name no longer matches its
row; the audiences are not exactly the three; an `into:` or `as:` names nothing on the lists; a list
entry would not end as exactly one live category; list names collide; a `target_id` is not live, of
the stated type and still named so; a protected genre (Fiction, Nonfiction, Religion & Spirituality,
Poetry) is not `keep`, or anything merges into Fiction or Nonfiction; `location` has no
`target_id`; or a split is malformed (see below). Re-running `apply` skips the validator and builder
once the run has decisions, and exits non-zero while any decision of the run is failed or stale,
printing the remedy for each: a failed one is fixed, reset to `proposed` and re-run; a stale one
(the category changed after the plan was built) is handled by hand and then marked `rejected`.

### Splits and `also:`

A `split` genre is two things at once (`Science Fiction Fantasy`, `History and Politics`). Its
books get each target that fits them, as recorded in the assignments file; a book the AI could not
place gets every target, and a book on the genre but missing from the file gets every target too
(`apply` prints how many). The first `into:` entry is the primary. If another decision already
produces it, the split genre merges into it; otherwise the genre is renamed to it and keeps its id.
Non-primary targets are stored in `extra_target_ids`.

The Applier runs splits first (renaming-mode, then merging-mode, by id), then plain renames, merge,
retype, parents, set_parent, delete, and last the keeps and renames that carry extra targets. Each
split first records its own books in `split_assignments` and acts only on those. A split, or a
keep or rename with extras, fails its decision if a target is missing, deleted or merged, or an
answer names an id outside the targets: a failed decision can be redone, a silently dropped tag
cannot. In merging mode a book that already had its own link to the primary keeps it.

`also:` on a `keep` or `rename` names genres every book of that genre necessarily belongs to
(`Romantasy` also Romance and Fantasy); its books are linked to them. It is not transitive.

### Saved searches, recommendation settings and the sync

Retypes keep ids, so stored ids keep working, and merged ids are followed at query time. A deleted
genre's id would match nothing, so `apply` removes applied deletes from the included and excluded
lists of saved searches and recommendation settings and prints what it changed. In the weekly
`data_migration:sync`, an already-mapped category keeps its new type, name and deleted flag; links
to a merged one land on its target; links to a deleted one are dropped; the saved-search and
recommendation-setting migrators drop deleted-and-unmerged ids from criteria. `CategoryItemMigrator`
also links a split genre's, or an `also:` genre's, extra targets. Known gap: pre-existing aliases of
a split genre are flattened onto its primary, so a new legacy book linked through one reaches only
the primary until the sync ends at launch.

The `/categories` Audiences tab appears only as edge-cached `/categories` pages expire after
audiences are created.

## Configuration

`config/initializers/categories.rb`:

- `config.x.books.browse_min_category_books` (5): the browse and filter-search threshold.
- `config.x.categories_cleanup.head_min_links` (20): direct links needed to be head tier.
- `tail_batch_size` (`{location: 10, subject: 1}`): tail categories per AI call, by type; set from calibration.
- `max_direct_locations` (15): books above this get the trim.
- `sample_titles` (5): sample books shown to the model per category.
- `estimated_cost_per_call` and `max_unforced_cost` ($50): the estimate and the limit above which `propose` needs `FORCE=1`. Re-check the price before a production run.
