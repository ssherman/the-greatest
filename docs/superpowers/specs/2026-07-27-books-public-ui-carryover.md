# Books public UI — decisions settled 2026-07-26/27 (deferred to spec 2)

Brainstormed before the Description subsystem was split out as spec 1.
These are agreed; do not re-litigate when spec 2 is written.

## Scope
Grid + `/book/:slug` + `/lists` + `/lists/:id`. Out: categories pages, search,
rankings methodology page, authors pages.

## URLs
- Canonical `/book/:slug` (singular, matches `/game/:slug`, `/album/:slug`).
- Legacy `/books/:id` and `/items/:id` with `constraints: {id: /\d+/}` → **301** to canonical.
- **Why singular/plural split is load-bearing:** 137 `Books::Book` rows have a purely
  numeric slug and 136 collide with a real book id (e.g. book id 15603 is titled "1952",
  slug `1952`; book id 1952 is a different book). One segment cannot serve both.
- `/lists/:id` stays numeric — legacy ids were preserved and `List` has no friendly_id,
  so these URLs are already identical to legacy.

## Grid
- Games-modelled 4-col card grid, `pagy`, RC #8 "May 2026" (`default_primary`, 24,242
  ranked items, all `Books::Book`).
- **No year filters in v1.** `Filters::YearFilter` only parses `/^\d{4}$/`; ranked books
  span -2400..2064 (165 negative, 530 null). Year filtering + the legacy
  `/the-greatest-books/{of,since,to,from}/:year` surface is its own increment.
- No per-book description on cards. NOTE for the spec: legacy's canonical view is the
  *list* view WITH `description_to_display`; `/v/grid` and `/v/table` are
  `noindex, follow`. Promoting the grid to canonical is an SEO-relevant change — call
  it out explicitly.
- `(/rc/:ranking_configuration_id)` scoping, `Cacheable` like games.

## Book detail page
Sections: description (obeying source preference), categories **grouped by
category_type** (genre/location/subject), "Appears on these lists" (→ `/lists/:id`).
- **Not** editions (85% coverage but cut).
- **Not** series — only 1 of 24,242 ranked books has one.
- Category badges are plain text, not links (no category pages in v1).

## User lists
Wire fully:
- `UserList::DOMAIN_SUBCLASSES` += `"books" => %w[Books::UserList]` — mandatory, it also
  gates `UserListStateController` and `UserListsController::ALLOWED_TYPES`.
- `UserList::DEFAULT_SUBCLASSES` += `Books::UserList` (`find_or_create_by!` on
  (user, list_type) → migrated users don't get dupes).
- `user_list_modal_controller.js` — add `Books::Book ↔ Books::UserList` to BOTH
  `_matchesListable` and `_listClassFor`.
- Books layout gains: `data-controller="user-list-state"`, `Toast::RegionComponent`,
  `UserLists::ModalComponent`, `_user_list_icon_template`, navbar "My Lists" link.
- `MyListsController#resolve_layout` += `when :books`. `csv_row`'s existing `else`
  branch already works — `Books::Book#release_year` exists now (D3 of the dummy-UI
  spec is stale).
- `GET /user_lists` → 301 `/my/lists`. `/user_lists/:id` already aliased to
  `my_lists#show` and books ids were preserved for exactly this.
- **Public-list viewing stays deferred** to increment 02d. Only 115 of 282,922
  `Books::UserList` rows are public (95 with items); those 404 for non-owners until 02d.

## Open question for the spec
Which books get a public route? 24,242 are ranked; 101,892 are on zero curated lists (they arrived
via the Goodreads importer and live on user lists). Not a content-quality problem — just decide
routing/indexability deliberately rather than by default.

## Data facts (dev, verified)
126,254 books · 37,111 with attached primary image · 58,214 authors · 1,044 lists ·
52,742 active categories (genre 20,270 / location 16,690 / subject 36,969).
Of 24,242 ranked books: categories 99.5%, editions 85%, subtitle 43%,
description 39% (pre-backfill), external links 26%, series 1.
