# User Lists — Part 2: UI & CloudFlare-Friendly Cached-Page Integration

## Status
- **Status**: Placeholder — to be rewritten when Part 1 is complete
- **Priority**: High
- **Created**: 2026-04-20
- **Started**:
- **Completed**:
- **Developer**:

> **This is a placeholder spec.** It captures intent, decisions already made, and research from the discovery phase so that whoever fills it out later has full context. It is **not** ready for agent hand-off as-is — rewrite against the Part 1 contracts before implementation.

## Overview

Build the user-facing UI for the `UserList` feature introduced in `user-lists-01-data-model.md`:
1. List management pages (uncached, per-user dashboards).
2. Public list show pages (cacheable when `public: true`).
3. Drag-and-drop reordering.
4. "Add to List" widgets on item index/show pages (which are CloudFlare-cached).
5. Read/Listened/Played/Watched "consumed" indicators on item cards (also cached-page-friendly).

**Depends on:** `user-lists-01-data-model.md` (models, `/user_lists` JSON endpoints, Pundit policies).

## Pre-agreed Decisions (from discovery phase)

1. **Drag-and-drop** for reordering — same UX intent as old site, but live on the list show page rather than a separate edit page.
2. **Public list URL pattern** — mirrors old site: `/user_lists/:id` (domain-scoped). Accessible to anyone if `public: true`.
3. **Add-to-list UX** — keep the same dropdown UI users are used to from the old site (reference: `../the-greatest-books` live site). Each list shows in the dropdown with an add/remove toggle.
4. **"Consumed" indicator** — small icon on item cards showing the user has read/listened/played the item (e.g., books show a "read" checkmark; games show "played"; etc.). Users specifically requested this on the old site.
5. **Import/export is out of scope** for this phase (Goodreads CSV, JSON export/import — deferred).
6. **Caching strategy — new approach, NOT the old heavy turbo_stream POST.**

## The Caching Problem (context for whoever implements this)

### Constraint
Public pages (`ranked_items#index`, item show pages) use the `Cacheable` concern which sets `Cache-Control: public, max-age=6h|24h` **and** calls `skip_session_for_caching` (sets `request.session_options[:skip] = true`). This means:
- Rails never emits a `Set-Cookie` header on these responses (CloudFlare bypasses cache if `Set-Cookie` is present).
- The server does **not know who the user is** on cached pages — `current_user` is effectively nil from the perspective of the rendered HTML.
- Any per-user element must be rendered client-side after the cached HTML loads.

### How the old site solved this (and why we're replacing it)
- On every page load, JS collected all book IDs, POSTed them to `/user_book_actions/index`, and the server returned a large turbo_stream response (~50–100KB) that replaced empty placeholder divs with user-specific dropdowns and badges.
- Worked, but heavy: large payload, full HTML re-render per book, one roundtrip blocking interactivity.

### Recommended new approach (pre-agreed in discovery)
**Lightweight JSON endpoint + `localStorage` + Stimulus CSS toggling.**

1. Public pages render cards with empty/neutral state and `data-listable-type` / `data-listable-id` attributes. This HTML is identical for every visitor — CloudFlare-safe.
2. A Stimulus controller (`user-list-state`) loads on signed-in pages. On `connect()`:
   - Immediately reads cached state from `localStorage` (per-domain key) and applies CSS classes / toggles buttons — **no flicker**, no network wait.
   - Fires a single `GET /user_list_state?domain=:domain` request in the background.
   - If the response version differs from the cached version, updates `localStorage` and re-applies state.
3. User mutations (add / remove / toggle) hit the existing `/user_lists/:id/items` endpoints from Part 1 directly. On success, update `localStorage` optimistically and toggle CSS classes locally.

**Payload comparison for a 100-item page:**
- Old: POST (~2KB of IDs) + response (~50–100KB of rendered HTML)
- New: GET (0 body) + response (~500 bytes of JSON integer arrays)

This pattern is ~100× lighter and works per-domain (music, games, movies, books) independently.

## Likely Interfaces & Contracts (to be finalized during rewrite)

### New endpoint(s) to add

| Verb | Path                     | Purpose                                                    | Auth        | Caching                  |
|------|--------------------------|------------------------------------------------------------|-------------|--------------------------|
| GET  | `/user_list_state`       | Compact per-user, per-domain state for hydrating cached pages | signed-in | `no-store, private`      |

**Query params:** `?domain=music|games|movies|books`

**Response shape (draft):**
```json
{
  "version": 1712341234,
  "domain": "music",
  "lists": [
    { "id": 42, "type": "Music::Albums::UserList", "list_type": "favorites", "name": "Favorite Albums" },
    { "id": 43, "type": "Music::Albums::UserList", "list_type": "listened",  "name": "Albums I've Listened To" }
  ],
  "memberships": {
    "Music::Album": {
      "101": [42],
      "207": [42, 43]
    },
    "Music::Song": {
      "9001": [51]
    }
  }
}
```

`memberships` is keyed by `listable_type` then by `listable_id`, valued by an array of `user_list_id`s the item is in. This is enough to render the dropdown's add/remove state and the "consumed" indicator with no per-item server hit.

`version` is a monotonic integer (e.g. `user.updated_at.to_i` bumped via `user.touch` whenever a `UserListItem` is saved/destroyed). Used by the Stimulus controller to skip re-application when nothing changed.

### Endpoints re-used from Part 1

- `POST /user_lists/:user_list_id/items` — add
- `DELETE /user_lists/:user_list_id/items/:id` — remove
- `POST /user_lists` — create custom list
- `POST /user_lists/:id/reorder` — drag-and-drop save
- `PATCH /user_lists/:user_list_id/items/:id` — update `completed_on`

### Likely pages / routes

**Per-domain (public, cacheable when list is public):**
- `GET /user_lists/:id` — public list show page. Cacheable **only** when the list's `public: true` — needs a controller-level decision (set `cache_for_show_page` conditionally; otherwise `prevent_caching`).

**Per-domain (uncached, per-user management):**
- `GET /my/lists` — index of the current user's lists for the current domain
- `GET /my/lists/:id/edit` — edit metadata (name, description, public flag, view_mode)

All management routes live under `/my/` or similar, scoped to `DomainConstraint` so each domain has its own (e.g., `thegreatestmusic.org/my/lists` vs. `thegreatestgames.org/my/lists`). Only lists of the appropriate STI type for the current domain are shown.

### Likely ViewComponents

- `UserList::CardComponent` — row/card for the user's own list dashboard
- `UserList::ShowComponent` — the show page (handles the three `view_mode` variants: default, table, grid)
- `UserList::AddToListDropdownComponent` — the dropdown injected on cached item cards. Must render a skeleton structure with `data-*` attributes so the Stimulus controller can toggle it client-side.
- `UserList::ConsumedBadgeComponent` — the small "read"/"listened"/"played" icon

### Likely Stimulus controllers

- `user-list-state` — hydrates cached pages from `/user_list_state` + `localStorage`.
- `user-list-sort` — SortableJS-based drag-and-drop on the list show page. Posts to `/user_lists/:id/reorder`.
- `user-list-form` — create/edit list metadata forms.

### Open questions for the rewrite

1. **Where exactly does the "Add to List" dropdown live on each card?**
   Discovery found the album card is a single `<a>` wrapping everything — nesting interactive elements requires restructuring. Game cards already have the right structure. Song list items need a new `<td>`. This work needs to be scoped explicitly.

2. **How does the consumed indicator work for subtypes that don't have a "consumed" concept?**
   Songs only have `favorites` — there's no "listened" list for songs. So songs probably don't get a consumed badge at all. Spec this out per-domain.

3. **Can non-signed-in users see an "Add to List" button that triggers the auth modal?**
   The old site did this. Likely yes — the Stimulus controller checks auth state from `firebase_auth_service` and swaps "Add to List" for "Sign in to save" on anonymous users.

4. **View mode switching** — server-side persisted (Part 1 has `view_mode` in the PATCH schema) or client-side only? Old site persisted it per-list.

5. **Notification toasts** after add/remove — match DaisyUI patterns already in the app? Old site used Notiflix.

6. **Public list indexing / discovery** — is there a `/user_lists` index showing *all* public lists? Probably deferred to a future phase, but worth explicitly noting.

## Agent Hand-Off

**Not ready for hand-off.** Before giving this to an agent:
1. Finish `user-lists-01-data-model.md` and confirm the actual API contracts match what's referenced here.
2. Revisit the open questions above with the product owner.
3. Fill out proper acceptance criteria, golden examples, and endpoint tables.

## Related Research

- Old-site reference: `docs/old_site/user-lists-feature.md` — specifically §"Global Bootstrapping Pattern" and §"Turbo Streams and Turbo Frames".
- Web-research findings (from discovery): JSON API + localStorage pattern beats CF Workers KV (sync complexity), beats lazy turbo frames with src (N+1 requests per card), and beats Turbo 8 morphing (requires uncached HTML). Service Workers only useful for offline support.
- New-site caching: `web-app/app/controllers/concerns/cacheable.rb`
- New-site auth state: `web-app/app/javascript/services/firebase_auth_service.js` (dispatches `auth:success`, `auth:signout` events on `window`)

## Documentation Updated
- [ ] Filled out properly before implementation
