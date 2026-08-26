# Reading Goals Migration — Design

- Date: 2026-08-26
- Branch: `reading-goals-migration`
- Status: Design approved in chat; written spec pending owner review
- Scope: Books reading goals, the reusable completion transition they depend on, legacy data migration, and public Cloudflare-cached pages. Goodreads importing and goals for other media are deferred.

## Summary

Port the legacy The Greatest Books reading-goals feature into the new app with feature parity for arbitrary and overlapping date ranges, multiple goals, public sharing, progress, goal CRUD, and book lists. Improve the presentation and completion-date workflow without adding forecasts, streaks, reminders, or recommendations.

The critical architectural change is that a reading goal will no longer persist its own copy of completed books or its own percentage. A goal stores only its definition. Its books and progress are a live projection of the owner's dated `UserListItem` records on their `Books::UserList` of type `read`.

This makes the Read list the single source of truth. It also repairs the legacy drift automatically: a removed Read item stops counting, a corrected completion date moves between applicable goals, and one completion can count toward every overlapping goal without synchronizing duplicate join rows.

## Goals

- Preserve every legacy reading goal, including multiple overlapping goals and arbitrary inclusive date ranges.
- Preserve goal ids and legacy URLs.
- Derive goal membership and progress from canonical Read-list completion dates.
- Match the legacy rule that a Reading → Read transition completes the book today, while a direct quick “I've read this” addition remains undated.
- Let users set, correct, or clear completion dates from their Books I've Read page, but not from the quick list widget.
- Remove a book from goal progress when it leaves the Read list.
- Reuse generic list-completion infrastructure so games, music, and other media can adopt equivalent transitions later.
- Reuse the app's existing controller caching, path pagination, and exact-URL Cloudflare purge facilities.
- Improve the UI while staying close to legacy feature scope.

## Non-goals

- Goodreads importing. It is not implemented in the new app and is explicitly excluded.
- Reading pace, on-track forecasts, streaks, reminders, recommendations, or social feeds.
- A generic cross-media Goal model. Reading goals are Books-specific; only completion/list transition infrastructure is shared.
- Game, music, movie, or other-media goal pages. The shared completion primitives should make those straightforward later, but this increment does not build them.
- Reproducing legacy `reading_goal_books` or stored `percentage_done` state.

## Legacy behavior and data audit

The legacy implementation lives in `/home/shane/dev/the-greatest-books/admin`:

- `app/models/reading_goal.rb`
- `app/models/reading_goal_book.rb`
- `app/lib/reading_goals_sync.rb`
- `app/controllers/reading_goals_controller.rb`
- `app/controllers/user_list_books_controller.rb`
- `app/views/reading_goals/`

### Feature behavior

- A user can own multiple goals with arbitrary inclusive `start_date` and `end_date` ranges.
- New goals default to the current calendar year, a target of 12 books, and private visibility.
- Public goals can be shared at `/reading_goals/:id`; private goals are limited to their owner and administrators.
- A goal shows its name, description, range, target, progress, and books, paginated 24 per page.
- Progress can exceed 100%; the legacy visual bar caps at 100% while the text remains truthful.
- Creating a goal synchronizes already-dated Read-list books in the goal's range.
- Adding a book to Read while it is on Reading removes the Reading membership and defaults `read_date` to `Date.current`.
- Adding directly to Read without a date does not count toward a goal.
- A completion date can be edited from the legacy Read-list page.

### Legacy synchronization defects

`ReadingGoalsSync#sync_book` removes a book from every goal and re-adds it to matching ranges. This handles the direct controller path, but not every mutation reaches it:

- Bulk deletion destroys Read memberships without synchronizing goals, leaving stale goal rows.
- The Goodreads repair path skips a book when it exists in any goal, so it can miss overlapping goals and changed dates.
- Goal membership, completion dates, and percentage are stored independently with no uniqueness constraint and almost no automated coverage.

### Read-only production-data audit

| Fact | Observed |
|---|---:|
| Reading goals | 399 |
| Goal owners | 374 |
| Public goals | 8 |
| Legacy goal id range | 1–438 |
| `reading_goal_books` rows | 1,813 |
| Duplicate `(reading_goal_id, book_id)` rows | 0 |
| Null goal-book dates | 0 |
| Goal-book dates outside their goal range | 0 |
| Stored goal books no longer on the owner's Read list | 13 |
| Stored goal-book dates disagreeing with the Read-list date | 18 |
| Dated Read items inside a goal range but missing from that goal | 41 |
| Goals with stored percentage drift | 1 |
| Goals currently above 100% | 15 |
| Calendar-year goals | 290 of 399 |

These defect classes are not necessarily disjoint, so their counts must not be added to predict a net row delta. The migration report will measure the resulting live projection directly.

Unusual but valid records are preserved. In particular, one goal spans 2009–2099, another is a public “500 books by 2035” goal, and several goals exceed their target. These are user intent, not corruption.

## Chosen architecture: live projection

Three approaches were considered:

1. **Live projection — selected.** Persist only the goal definition and query dated Read-list items for books and progress.
2. **Rebuilt join.** Keep `reading_goal_books` but make it deterministic with constraints and complete synchronization. Rejected because it retains two sources of truth and recreates the defect class found in legacy.
3. **Asynchronous projection.** Maintain goal membership with events/jobs. Rejected because the data volume does not justify eventual consistency or the extra failure modes.

The live query is supported by the existing `(user_list_id, completed_on)` index on `user_list_items`. With 399 current goals and one user's Read list per query, a stored projection is unnecessary.

## Data model

The only new persisted model is `Books::ReadingGoal`, backed by `books_reading_goals`:

| Column | Type | Rules |
|---|---|---|
| `id` | bigint | Legacy ids preserved below 10,000 |
| `user_id` | bigint | Not null, FK to `users` |
| `name` | string | Not null |
| `description` | text | Optional |
| `target_count` | integer | Not null, greater than zero |
| `starts_on` | date | Not null |
| `ends_on` | date | Not null and on/after `starts_on` |
| `public` | boolean | Not null, default false |
| timestamps | datetime | Legacy values preserved |

Rails validations enforce every rule above, including a non-blank name. Database null/check constraints enforce the positive target and ordered dates. An index on `user_id` supports owner listing; an index on `(user_id, public, starts_on, ends_on)` supports finding a user's public goals containing an old or new completion date.

There is deliberately no percentage column and no goal/book join table. Multiple goals can select the same `UserListItem` without duplicating state.

### Reserved ids

The table is new, but the application may create goals before the eventual legacy cutover. Its creation migration therefore starts the primary-key sequence at 10,000. The legacy preflight must confirm:

- `MAX(legacy reading_goals.id) < 10,000` — currently 438.
- No target row below 10,000 conflicts with a different legacy id.
- Every new-app-created goal id is at least 10,000.

The migrator preserves ids below 10,000 and must never use a plain `reset_pk_sequence!` that could lower the sequence into the reserved range. Finalization leaves the next generated id above both 10,000 and the largest existing target id.

## Progress query

`Services::Books::ReadingGoals::ProgressQuery` is the single implementation used by owner and public pages.

For a goal it:

1. Finds the owner's `Books::UserList` with `list_type = read`.
2. Selects that list's `UserListItem` rows with `listable_type = "Books::Book"`.
3. Requires non-null `completed_on` within the inclusive `starts_on..ends_on` range.
4. Orders by `completed_on DESC, user_list_items.id DESC` for stable pagination.
5. Preloads the standard Books card associations and paginates 24 per page.

The query exposes the selected relation, count, percentage, completion state, and capped visual percentage. The displayed count and percentage may exceed the target; only the progress bar's width is capped at 100%.

If a legacy user has no Read list, the query returns an empty result rather than failing.

## Completion and list-transition behavior

The completion date lives on the Read-list `UserListItem`, not on the Reading membership and not on the goal.

### Rules

- **Reading → Read:** transactionally remove the Reading membership, create or retain the Read membership, and set `completed_on = Date.current` when the Read item has no existing date.
- **Direct quick add to Read:** when no Reading membership exists, add the Read membership with `completed_on = nil`.
- **Already-dated Read item:** never overwrite an existing completion date merely because a stale Reading membership also exists; remove Reading and preserve the historical date.
- **Any add to Read:** remove a matching Reading membership if one exists.
- **Remove from Read:** destroy the Read item. It immediately disappears from every goal projection.
- **Edit completion:** the owner can set, replace, or clear `completed_on` from the Books I've Read page.
- **Clear completion:** retain the Read membership but remove it from every goal projection.
- **Quick widget:** never asks for or edits a completion date.

The Reading row can safely be destroyed because the completion date is written to the separate Read row in the same transaction.

### Reusable services

Generic services under `Services::UserLists` own add/remove/completion mutations and return the project's standard `Result` object. They operate on list types and subclass declarations rather than Books classes.

`Books::UserList` declares that `reading` is a transition source for `read`, and that `read` supports completion dates. A future `Games::UserList` or other domain can declare its corresponding source and completed list types without copying controller logic.

The generic mutation result includes the old and new completion dates and the affected listable. Books-specific orchestration uses that result to invalidate public reading-goal pages. The generic service does not know that reading goals exist.

Mutations are transactional. A failure cannot leave a half-completed move between Reading and Read.

## Routes, controllers, and authorization

All feature code is Books-namespaced and the routes are constrained to the Books domain.

### Public and shareable surface

- `GET /reading_goals/:id`
- `GET /reading_goals/:id/page/:page`

`Books::ReadingGoalsController#show` renders a public goal identically for every viewer. A private goal can be shown to its owner or an administrator only with caching disabled; everyone else receives an uncached 404.

### Owner surface

- `GET /my/reading-goals`
- `GET /my/reading-goals/new`
- `POST /my/reading-goals`
- `GET /my/reading-goals/:id/edit`
- `PATCH /my/reading-goals/:id`
- `DELETE /my/reading-goals/:id`

`Books::My::ReadingGoalsController` requires authentication and scopes every lookup to the current user unless an explicit administrator path is used. `Books::ReadingGoalPolicy` centralizes view and mutation rules.

Legacy owner URLs redirect permanently where they do not conflict with the public show URL:

- `/reading_goals` → `/my/reading-goals`
- `/reading_goals/new` → `/my/reading-goals/new`
- `/reading_goals/:id/edit` → `/my/reading-goals/:id/edit`

### Completion-date endpoint

`PATCH /user_list_items/:id/completion` updates or clears only `completed_on` for a `UserListItem` owned by the current user and belonging to a list type declared completion-capable. It delegates to the generic completion service; it does not expose general `UserListItem` mass assignment.

### Viewer-specific state

The cacheable public page contains no owner-specific server-rendered controls. A small authenticated, `no-store` reading-goal state endpoint follows the existing review/list state pattern and can reveal a Manage link to the owner or an administrator after hydration.

## Caching and invalidation

No new caching subsystem or endpoint-specific cache headers are introduced.

### Controller caching

- Confirmed-public goal pages call the existing `Cacheable#cache_for_show_page`: 24-hour public caching, one-hour stale-while-revalidate, and session skipping so Rails emits no `Set-Cookie` header.
- Private goals, 404 responses, state endpoints, owner pages, and mutations call the existing `prevent_caching` behavior.
- Public HTML uses the cache-safe Books layout and contains no session-dependent body, CSRF token used for mutations, personalized navigation, or owner-only action.

### Canonical pages

The feature reuses `PathBasedPagination`:

- Page 1 is only `/reading_goals/:id`.
- Later pages use `/reading_goals/:id/page/:page`.
- `?page=N`, `/page/1`, invalid numerals, and pages beyond the final page redirect or 404 according to the existing canonical pagination rules and never create cacheable duplicate bodies.

### Exact-URL purge

`Services::Books::ReadingGoals::CachedUrls` produces JSON-native full URL strings for every configured Books host. For a supplied projected count it returns the base show URL and all existing path-based pagination URLs.

The caller captures URLs before and after a mutation and purges the union, which covers a final page that disappears when a count shrinks. Relevant changes are:

- Goal name, description, target, range, or visibility changes.
- Goal deletion.
- Reading → Read with today's completion date.
- Removing a dated item from Read.
- Setting, changing, or clearing a Read completion date.

For a list mutation, the Books orchestrator finds the user's public goals whose inclusive range contains either the old or new non-null completion date. An undated direct Read addition affects no goal and causes no purge.

A Books-namespaced Sidekiq job passes URL batches to the existing `Cloudflare::PurgeService#purge_urls(:books, urls)`, chunking to the same per-request limit already used by cached news pages. It is enqueued explicitly after successful writes, never from a model callback. Development and CI skip the external call when the purge token is absent.

Changing a goal from public to private is the only synchronous purge. The origin is made private first, then every pre-change public URL is purged with the same existing service. Full success is reported only after Cloudflare confirms. On failure, the origin remains private, the user is told the edge purge is not yet confirmed, an alert is logged, and retries are queued. Development and test treat the absent edge-cache configuration as a successful no-op. As with every currently cacheable public page, exact Cloudflare purge cannot recall copies a visitor's browser already stored while the page was public; this feature intentionally retains the site's existing browser-cache semantics.

## User experience

The implementation follows `.claude/agents/ui-engineer.md`, the current Books ViewComponent/Hotwire patterns, WCAG AA, Tailwind 4, and DaisyUI 5. Before implementing form markup, the pinned `docs/external-libraries/daisyui-llms.txt` reference must be consulted as required by project guidance.

### Navigation

Do not add Reading Goals as another top-level desktop item. Replace the separate signed-in Books links with one client-hydrated **My Books** group:

1. Lists
2. Reading Goals
3. Reviews
4. Saved Searches

Desktop renders a single dropdown. The mobile drawer renders an inline My Books section with the child links visible, avoiding an extra disclosure tap. The whole group ships hidden in cacheable HTML and is revealed through the existing signed-in state controller.

The label deliberately scales by domain: My Books, My Games, and My Music. Only the Books group gains Reading Goals in this increment.

### Owner index

The Reading Goals page has a clear create action and groups cards by `Date.current`: active goals first, then upcoming, then finished. Active goals order by soonest `ends_on`, upcoming goals by soonest `starts_on`, and finished goals by most recent `ends_on`, with id as the stable tie-breaker. Cards show name, inclusive date range, visibility, `X of Y books`, and a progress bar. Available actions are View, Edit, Delete, Copy Share Link, with sharing offered only for public goals.

### Goal page

- Title, owner, optional description, inclusive date range, and progress summary.
- Truthful count and percentage above 100%, with visual width capped at 100%.
- Responsive standard Books cover grid with title, author, and completion date.
- Stable newest-completion-first order and 24 books per page.
- Useful empty state when the period contains no dated Read items.
- Client-hydrated Manage action for authorized viewers.
- Accessible progress text that does not rely on color alone.

### Form

Fields are name, optional description, positive target, start date, end date, and Public. Defaults preserve legacy behavior: the current calendar year, target 12, `My <year> Reading Goal`, `My yearly reading goal`, and private visibility. Forms use semantic labels, help text, inline validation, and a confirmation before deletion. Visibility help explains that only public goals can be shared.

### Books I've Read

Each item gains an explicit Edit completion date action that opens an accessible dialog containing a Turbo-backed date form. The owner can set, correct, or clear the date.

Feedback distinguishes the two quick flows:

- Reading → Read confirms completion today and that matching goals update.
- Direct undated Read confirms the list addition and points to Books I've Read if the user wants to add a date and count it toward goals.

## Legacy migration

### Source mapping

`LegacyBooks::ReadingGoal` is a read-only model on the existing legacy connection. `Services::BooksMigration::ReadingGoalMigrator` uses the established bulk-upsert framework and runs after `user_list_items`.

| Target | Legacy source | Rule |
|---|---|---|
| `id` | `id` | Preserve |
| `user_id` | `user_id` | Preserve; real FK validates owner |
| `name` | `name` | Preserve |
| `description` | `description` | Preserve |
| `target_count` | `number_of_books` | Preserve and require positive |
| `starts_on` | `start_date` | Preserve |
| `ends_on` | `end_date` | Preserve |
| `public` | `public` | Coalesce null to false |
| timestamps | timestamps | Preserve |
| — | `percentage_done` | Drop; derive live |

`reading_goal_books` is not migrated. The canonical completion dates were already migrated from legacy `user_list_books.read_date` to `user_list_items.completed_on`; the progress query rebuilds goal membership from those rows.

### Idempotency and failures

The migrator upserts on preserved goal id, preserves timestamps without callbacks, and is safe to rerun. It fails loudly for an invalid target, invalid date range, missing owner, or reserved-id violation. It does not skip malformed goals silently.

### Intentional data repair

The post-import projection is authoritative:

- The 13 stored goal rows whose books are no longer Read disappear.
- The 18 conflicting goal-book dates use canonical Read-list dates and may move between goals.
- The 41 currently missing dated Read items appear in every matching goal.
- The one stored percentage mismatch disappears because percentage is derived.
- Overlapping goals automatically receive the same qualifying completion.

No goal definition is altered as part of these repairs.

## Error handling

- Goal model validation rejects blank names; model and database constraints reject non-positive targets, missing dates, and reversed ranges.
- Owner mutations return the project's `Result` shape and render inline errors without partial writes.
- Generic list transitions and completion edits are transactional.
- Unauthorized private-goal access returns an uncached 404 rather than exposing existence.
- Public-page cache purges are explicit orchestration after successful writes, not hidden callbacks.
- Background purge failures log actionable context and retry according to Sidekiq policy.
- The public-to-private path surfaces an unconfirmed purge rather than falsely reporting complete revocation.

## Testing strategy

Implementation follows test-driven development and project generators. Coverage includes all public service methods.

### Models and queries

- `Books::ReadingGoal` associations, validations, database constraints, and ordering scopes.
- ProgressQuery inclusive start/end boundaries.
- Nil completion dates excluded.
- Overlapping goals select the same item.
- Wrong owner, wrong domain, wrong list type, and non-Book items excluded.
- Count, percentage, completion, over-100 display, stable ordering, and pagination.
- Missing Read list returns an empty projection.

### Generic list mutations

- Direct Read addition with no Reading membership remains undated.
- Reading → Read removes Reading and sets today on an undated Read item.
- Existing historical Read date is preserved while stale Reading is removed.
- Removing Read destroys its contribution.
- Setting, replacing, and clearing completion dates.
- Unauthorized or non-completion-capable items rejected.
- Failure rolls back both sides of a transition.

### Controllers and policies

- Authenticated owner CRUD and ownership scoping.
- Public anonymous show.
- Private owner/admin show is no-store; unauthorized access is no-store 404.
- Confirmed-public responses use `cache_for_show_page` and emit no session cookie.
- Canonical path pagination and past-last-page 404 behavior.
- State endpoint is authenticated and no-store.
- Legacy redirects.

### Cache invalidation

- Full URL generation for every configured Books host.
- Base and every existing page included.
- Before/after union retains disappeared final pages.
- Old/new completion dates select exactly the affected public goals.
- Undated additions enqueue nothing.
- Jobs pass JSON-native arguments, skip without a token, chunk requests, and call `Cloudflare::PurgeService#purge_urls(:books, urls)`.
- Public-to-private uses the synchronous path and schedules retries on failure.

### Migration

- Every source column maps correctly; percentage is absent.
- Ids and timestamps are preserved.
- Reserved-id preflight and sequence floor at 10,000.
- Missing owner and invalid goal fail loudly.
- Rerun is idempotent.
- Migration ordering follows users → Books user lists/items → reading goals.

### UI and end-to-end

- Component coverage for progress and goal cards where behavior exists.
- Playwright covers goal CRUD, public sharing, private denial, Reading → Read progress, Read removal, and setting/changing/clearing completion dates.
- Responsive checks cover desktop My Books dropdown and the inline mobile drawer group.
- Accessibility checks cover labels, keyboard operation, focus, progress semantics, and contrast.

Final verification runs `bin/rails test`, relevant system tests, `bundle exec standardrb`, frontend builds, and the new Playwright flow.

## Migration verification report

Against the real legacy database, the cutover report must assert:

| Assertion | Expected |
|---|---:|
| Imported goals | 399 |
| Distinct owners | 374 |
| Public goals | 8 |
| Preserved id range | 1–438 |
| Missing imported owner | 0 |
| Target ids in reserved low range not matching legacy | 0 |
| Persisted goal/book join rows | 0 |
| Persisted percentages | 0 |

It then compares each legacy goal's stored membership with the new live projection and reports the repaired categories separately: stale memberships, date disagreements, missing qualifying books, and percentage drift. Those expected differences are evidence of repair, not migration failure. A second run must leave goal definitions and projections unchanged.

## Deployment sequence

1. Merge the schema and application code generated through the project conventions.
2. Deploy the new table with its sequence starting at 10,000.
3. Reconfirm the legacy maximum id is below the reserved ceiling.
4. Run the reading-goal migrator after user-list items are present.
5. Run the migration verification report, including the intentional-repair comparison.
6. Verify anonymous public and authenticated private behavior.
7. Verify Cloudflare behavior on a public goal: first request `MISS`, subsequent request `HIT`, mutation exact-purge, then `MISS`.
8. Confirm public cacheable responses have no `Set-Cookie`, while owner/private responses are `no-store`.

No destructive development-database operation is part of this work.
