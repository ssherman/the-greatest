# User Lists — Part 2e: Add an Item From Within a List Page

## Status
- **Status**: Completed
- **Priority**: Medium
- **Created**: 2026-06-04
- **Started**: 2026-06-21
- **Completed**: 2026-06-27
- **Developer**: Shane Sherman (with Claude Code)

## Overview
Let a signed-in owner add items to a user list **from the list's own show page** (`/my/lists/:id`) via an inline search/autocomplete box — instead of having to navigate to each album/song/game page and use the 02a "Add to List" widget.

This mirrors the old app's "Add Book" modal (`docs/old_site/user-lists-feature.md` → `AddBookToUserListComponent` / `add_book_controller.js`), which provides typeahead search over existing items and adds the selected one to the current list.

This is split out of Part 2 deliberately: it depends on per-domain **search/autocomplete infrastructure** that the dashboard/show/edit work does not need.

### Resolved scope decisions (from discovery, 2026-06-21)
1. **Show page only.** The edit page (`/my/lists/:id/edit`) is a **02f** deliverable that is *Not Started* (`MyListsController` currently has only `index` + `show`). The same `UserLists::Show::AddItemComponent` can be dropped into the edit view when 02f ships; this spec does not build the edit page.
2. **Inline search box**, not a modal: an always-visible typeahead panel rendered above the item list. Simpler (no singleton-dialog plumbing) and more discoverable. Select-a-result adds it immediately — no separate "Add" button.
3. **Turbo Frame reload of just the item list** after a successful add (not a full-page reload). The item list + count are wrapped in `<turbo-frame id="list_items">`; the add controller calls `frame.reload()`, re-rendering only that region through the `my_lists#show` action (so it stays correct for the current view mode / sort / page) while the rest of the page — including the success toast — is untouched. (A full `window.location.reload()` was the first cut but was changed because it looked unpolished **and** destroyed the success toast before it was visible. Turbo Stream append from the add endpoint was rejected: it would duplicate `show`'s view-mode/sort/pagination rendering in the items controller.)

### Non-goals
- Creating brand-new domain records (the old app's "add manually / from URL" path). Items added here are existing `Music::Album` / `Music::Song` / `Games::Game` records only.
- The edit-page affordance (deferred to 02f, which owns the edit page).
- Movies/Books: `Movies::Movie` has no search index yet and books has no domain; the search box does not render for them (same deferral as 02a).
- Anything already covered by Part 2 (dashboard, show, edit, reorder, view modes, `completed_on`) or 02a (the per-item widget).

## Context & Links
- Parent specs: `docs/specs/completed/user-lists-02-ui-and-cached-page-integration.md` (Phase A — dashboard/show, **shipped**) and `docs/specs/user-lists-02f-list-management-and-editing.md` (Phase B — create/edit/delete; reserves the "Add item" slot — *not started*)
- Reuses the add endpoint shipped in 02a: `POST /user_lists/:user_list_id/items` (`docs/specs/completed/user-lists-02a-add-to-list-widget.md`)
- Old-app reference: `docs/old_site/user-lists-feature.md` (AddBookToUserListComponent, autocomplete)
- Search backend (OpenSearch autocomplete services, reused as-is):
  - `web-app/app/lib/search/music/search/album_autocomplete.rb`
  - `web-app/app/lib/search/music/search/song_autocomplete.rb`
  - `web-app/app/lib/search/games/search/game_autocomplete.rb`
- Reused frontend building blocks: `web-app/app/components/autocomplete_component.rb` (+ template) and `web-app/app/javascript/controllers/autocomplete_controller.js` (debounced typeahead, dispatches `autocomplete:selected`).

## Interfaces & Contracts

### Domain Model (diffs only)
None. No migration. Reuses the existing `UserList` STI (`listable_class`) and `UserListItem` (uniqueness index) from Part 1/02a.

### Endpoints

| Verb | Path | Controller#Action | Purpose | Auth |
|------|------|-------------------|---------|------|
| GET | `/listable_search?listable_type=…&q=…` | `listable_searches#index` | Type-scoped typeahead for the add box | signed-in |
| POST | `/user_lists/:user_list_id/items` | `user_list_items#create` | Add the selected item (**reused from 02a**) | owner |

> Source of truth: `web-app/config/routes.rb`. The search route is global (non-domain-constrained), alongside the other `user_list*` routes. **CSRF**: standard `<meta name="csrf-token">` — the `/my/lists/:id` page is never cached, so no `/user_list_state` token dance is needed (unlike the 02a cached card widget). **Caching**: `prevent_caching` (`no-store, … private`).

### Schemas (JSON)

**Request — `GET /listable_search`**: query params `listable_type` (one of `Music::Album`, `Music::Song`, `Games::Game`) and `q` (the typed text).

**Response — `200`** (array, in search-relevance order; capped at 10):
```json
[
  { "value": 101, "text": "Kind of Blue — Miles Davis" },
  { "value": 102, "text": "Breath of the Wild (2017)" }
]
```
- `value` = the listable record id (becomes `user_list_item[listable_id]` on add).
- `text` = dropdown label: `"Title — Artists"` for album/song, `"Title (year)"` for games (year omitted when nil).
- Unsupported/blank `listable_type` or blank `q` → `[]` (friendly for typeahead; never an error).

**Add request/response**: unchanged from 02a — `POST {user_list_item: {listable_id}}` → `201 {user_list_item: {…}}`, `409 conflict` on duplicate, `422 validation_failed` on wrong type.

### Stimulus / Event contract
- `AutocompleteComponent` fetches `GET {url}&q=…` and, on selection, dispatches a bubbling `autocomplete:selected` `CustomEvent` with `detail.item = {value, text}`.
- `user-list-add-item` controller (on the wrapping div, `data-action="autocomplete:selected->user-list-add-item#add"`) reads `detail.item.value`, POSTs the add with the meta CSRF token, then: (a) records the new membership in the singleton `user-list-state` cache via `applyMutation` (mirrors the modal's `_afterMutation`, using the `user_list_item` returned by the add) so the per-item "on these lists" widget is accurate, (b) fires a `toast:show` event (`Added "{label}" to {list}`), (c) clears + refocuses the search box, and (d) reloads the `list_items` Turbo Frame (`frame.reload()`, falling back to a full reload if Turbo/the frame is absent). The cache update happens **before** the frame reload so the new item's widget reads correct state on `connect()`. On error (incl. 409) it shows an error toast and leaves the list as-is for retry. A `submitting` guard prevents double-add.
- The item list + count live inside `<turbo-frame id="list_items">` (rendered by `my_lists#show`), so the frame reload swaps only that region. The search box and toast region sit **outside** the frame, so the box's controller stays alive and the toast persists.

### Behaviors (pre/postconditions)
- **Pre**: signed-in owner on `/my/lists/:id` for a searchable list (album/song/game).
- **Post (success)**: a `UserListItem` is created (appended to the end via the model's `set_position`); a success toast shows `Added "{label}" to {list name}` and persists; the `list_items` Turbo Frame reloads in place (count + list update) without a full-page flash; the new item's per-item list widget shows it as on this list (the `user-list-state` cache is updated before the reload); the search box is cleared and refocused.
- **Edge cases**:
  - Duplicate → 409 → error toast "Item already in list"; **no frame reload**, search box untouched.
  - Wrong type (impossible from this UI; the endpoint is type-scoped) → 422, defended at the model layer.
  - Non-searchable list (movies) → the box does not render at all (`AddItemComponent#render?` is false).
  - Anonymous hitting `/listable_search` directly → 401.
  - Blank/short query → empty dropdown ("No results"), no add.

### Non-Functionals
- **Auth**: search requires sign-in; add requires list ownership (owner-only `current_user.user_lists.find`, 404 otherwise — 02a).
- **Caching**: search + add both `no-store, … private`.
- **Performance**: typeahead returns ≤10 hits; one OpenSearch autocomplete call + one `WHERE id IN (…)` load with `includes(:artists)` (no N+1). Debounced 300ms client-side; in-flight requests aborted.
- **Single source of truth**: which listable types are searchable lives only in `Search::ListableAutocomplete::CONFIGS`; both the endpoint and the component consult it.

## Acceptance Criteria
- [x] `GET /listable_search` (anonymous) returns 401.
- [x] `GET /listable_search?listable_type=Music::Album&q=…` (signed-in) returns `[{value, text}]` in service order, album/song labelled `"Title — Artists"`, games `"Title (year)"`.
- [x] Unsupported `listable_type` (e.g. `Movies::Movie`) and blank `q` return `[]` (no error, no service call for unsupported types).
- [x] Search responses carry `Cache-Control: no-store, … private`.
- [x] `Search::ListableAutocomplete.searchable?` is the single source of truth; `AddItemComponent#render?` gates on it (renders for album/song/game lists, renders nothing for movies lists).
- [x] The show page renders the inline search box above the item list (outside the frame) for searchable lists; the item count + list are wrapped in `<turbo-frame id="list_items">`; existing show/CSV/view-mode behavior is unchanged.
- [x] New Stimulus controller `user-list-add-item` registered in `controllers/index.js`; the bundle builds.
- [x] **Manual**: typing in the box shows matching album/song/game results; selecting one adds it, shows a persistent success toast, reloads only the `list_items` frame (count + new item update, no page flash), and clears/refocuses the box; a duplicate shows an error toast with no frame reload. The newly-added item's per-item "on these lists" widget reflects the membership immediately. (Browser-verified by the developer on the music/games dev subdomains, 2026-06-27.)
- [x] Existing suite green; new PORO + controller + component tests cover the server-side criteria above.

### Golden Examples
```
GET /listable_search?listable_type=Music::Album&q=kind+of+blue   (signed-in)
→ 200 [{"value": 101, "text": "Kind of Blue — Miles Davis"}, …]

User clicks the result →
POST /user_lists/42/items  {"user_list_item": {"listable_id": 101}}
→ 201 → toast 'Added "Kind of Blue — Miles Davis" to Favorite Albums'
     → list_items Turbo Frame reloads (count + new row), page does not flash, box clears
(duplicate → 409 → toast "Item already in list", no frame reload)
```

---

## Agent Hand-Off
- Followed the patterns established by Part 2 and 02a; reused the 02a `items#create` endpoint for the actual add and `AutocompleteComponent`/`autocomplete_controller.js` for the typeahead.
- Did not duplicate the dashboard/show/edit surface from Part 2, and did not build the 02f edit page.

### Sub-Agent Plan (executed)
1. `code-explorer` ×3 → mapped the user-lists feature, the per-domain OpenSearch search surface, and existing autocomplete/Stimulus patterns. Verdict: a signed-in JSON typeahead endpoint had to be added; everything else was reusable.

### Test Seed / Fixtures
- Reused `test/fixtures/user_lists.yml` (album/song/game/movies favorites), `music/albums.yml`, `music/songs.yml`, `games/games.yml`. No new fixtures.

---

## Implementation Notes (living)
- **Approach taken**: a small search PORO (`Search::ListableAutocomplete`) is the single source of truth mapping `listable_type → {service, model, includes}` and serializing `{value, text}` rows. A thin signed-in `ListableSearchesController#index` delegates to it. A `UserLists::Show::AddItemComponent` renders the inline box (only when `render?`/`searchable?`), reusing `AutocompleteComponent`. A new `user-list-add-item` Stimulus controller listens for `autocomplete:selected`, POSTs to the 02a endpoint, toasts, clears the box, and reloads the `list_items` Turbo Frame.
- **Important decisions**:
  - New **global** route `GET /listable_search` (not a `format.json` on the per-domain HTML search controllers) — user lists are themselves global, and this keeps the endpoint type-scoped and admin-free.
  - **Meta CSRF** (not the 02a `/user_list_state` token) because `/my/lists/:id` is never cached.
  - **Turbo Frame reload over full reload** (changed after first testing): the item list + count are wrapped in `<turbo-frame id="list_items">` and the controller calls `frame.reload()`, so only that region re-renders (through `show`, staying correct for the active view mode/sort/page) and the success toast — fired just before — survives. A full `window.location.reload()` had been destroying the toast before it rendered. Turbo Stream append was rejected because the items controller would have to duplicate `show`'s view-mode/sort/pagination rendering. The frame keeps `show` as the single renderer of the list.
  - The search box + toast region stay **outside** the frame so the box's Stimulus controller isn't torn down mid-callback and the toast persists; the box is cleared/refocused in JS for the next add.
  - Empty `includes([])` raises in Rails — apply `includes` only when the config lists associations (games need none).

### Key Files Touched (paths only)
**New**
- `web-app/app/lib/search/listable_autocomplete.rb`
- `web-app/app/controllers/listable_searches_controller.rb`
- `web-app/app/components/user_lists/show/add_item_component.rb` (+ `add_item_component/add_item_component.html.erb`)
- `web-app/app/javascript/controllers/user_list_add_item_controller.js`
- `web-app/test/lib/search/listable_autocomplete_test.rb`
- `web-app/test/controllers/listable_searches_controller_test.rb`
- `web-app/test/components/user_lists/show/add_item_component_test.rb`

**Modified**
- `web-app/config/routes.rb` (search route)
- `web-app/app/javascript/controllers/index.js` (register `user-list-add-item`)
- `web-app/app/views/my_lists/show.html.erb` (render the component; wrap count + list in `turbo-frame#list_items`)

### Challenges & Resolutions
- `.includes(*[])` (empty splat) raised `ArgumentError: The method .includes() must contain arguments.` — guarded with `if config[:includes].any?`.
- First cut used `window.location.reload()`, which fired the success toast and then immediately reloaded the page — so the toast was never visible, and the full-page flash looked unpolished. Switched to a `list_items` Turbo Frame: only the count + list re-render (via `show`), the toast persists, and the box clears for the next add.
- After moving to the frame reload, the new item's per-item "on these lists" widget rendered stale: it reads the `user-list-state` cache, which the direct `fetch` add never updated (unlike the 02a modal, which calls `applyMutation`). Fixed by calling `applyMutation` with the membership tuple from the add response **before** reloading the frame, so the freshly-rendered widget reads correct state on `connect()`. Falls back to `user-list-state#refresh` if the cache isn't hydrated yet.

### Deviations From Plan
- Scope narrowed to the **show page only** (the spec originally envisioned show + edit); the edit page does not exist yet and belongs to 02f. The component is ready to be reused there.

## Acceptance Results
- 2026-06-21: New tests green (PORO 7, controller 6, component 4); related suites green (`my_lists` 26, `user_list_items`, `user_lists`, `user_lists` components). JS bundle builds.
- 2026-06-27: Manual browser verification completed on the music/games dev subdomains — type→pick→add reloads only the `list_items` frame (no page flash), the success toast persists, the box clears/refocuses, duplicates show an error toast with no reload, and the new item's per-item list widget is accurate. Code review completed (no blocking issues; minor non-blocking polish noted: no JS-unit/e2e coverage for the `user-list-add-item` controller, and 409 duplicates surface as an error-styled toast). Full suite green after a concurrent `bundle update` / `yarn update`: **4205 runs, 10985 assertions, 0 failures, 0 errors, 0 skips**; `standardrb` clean; bundle builds across all five entry points. Feature **Completed**.

## Future Improvements
- Wire `AddItemComponent` into the 02f edit page once it lands.
- Extend `Search::ListableAutocomplete::CONFIGS` to movies/books when those indices exist.

## Related PRs
- _to be filled when the PR is opened_

## Documentation Updated
- [x] This spec — contracts, acceptance criteria, implementation notes, deviations (serves as the feature's source of truth; `docs/features/user-lists.md` referenced by older specs does not exist in this repo)
