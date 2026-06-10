# User Lists — Part 2e: Add an Item From Within a List Page

## Status
- **Status**: Not Started (placeholder — to be expanded before implementation)
- **Priority**: Medium
- **Created**: 2026-06-04
- **Developer**: TBD

## Overview
Let a signed-in owner add items to a user list **from the list's own pages** (the `/my/lists/:id` show page and `/my/lists/:id/edit` page), via a search/autocomplete affordance — instead of having to navigate to each album/song/game page and use the 02a "Add to List" widget.

This mirrors the old app's "Add Book" modal (`docs/old_site/user-lists-feature.md` → `AddBookToUserListComponent` / `add_book_controller.js`), which provides typeahead search over existing items and adds the selected one to the current list.

This is split out of Part 2 deliberately: it depends on per-domain **search/autocomplete infrastructure** that the dashboard/show/edit work does not need.

### Non-goals
- Creating brand-new domain records (the old app's "add manually / from URL" path). Items added here are existing `Music::Album` / `Music::Song` / `Games::Game` records only.
- Anything already covered by Part 2 (dashboard, show, edit, reorder, view modes, `completed_on`) or 02a (the per-item widget).

## Context & Links
- Parent specs: `docs/specs/completed/user-lists-02-ui-and-cached-page-integration.md` (Phase A — dashboard/show) and `docs/specs/user-lists-02f-list-management-and-editing.md` (Phase B — create/edit/delete; reserves the "Add item" toolbar slot this spec fills)
- Reuses the add endpoint shipped in 02a: `POST /user_lists/:user_list_id/items` (`docs/specs/completed/user-lists-02a-add-to-list-widget.md`)
- Old-app reference: `docs/old_site/user-lists-feature.md` (AddBookToUserListComponent, autocomplete)
- Existing search controllers to model autocomplete after: `web-app/app/controllers/music/searches_controller.rb`, `web-app/app/controllers/games/searches_controller.rb` (verify their JSON/search surface during expansion)

## Open Questions (resolve before implementation)
1. **Autocomplete source**: is there a JSON search endpoint per domain/listable suitable for typeahead, or must one be added? (`music/searches`, `games/searches` exist as HTML — confirm a JSON mode or add a scoped autocomplete endpoint.)
2. **Listable scoping**: a music album list must search only albums (not songs). How is the search scoped per list's `listable_class`?
3. **Add UX**: modal (old-app style) vs inline search box on the show/edit page.
4. **Where it appears**: show page, edit page, or both. The Part 2 toolbar reserves an "Add item" slot — wire it here.
5. **Add path**: reuse the existing JSON `POST /user_lists/:user_list_id/items` from 02a (preferred) and refresh the page/section on success.
6. **Duplicates**: the add endpoint already returns 409 on duplicates — surface a friendly toast.

## Interfaces & Contracts
_To be expanded._ Expected shape: a new autocomplete/search JSON endpoint (or a JSON mode on the existing per-domain search), a Stimulus controller driving typeahead + add via the 02a item-create endpoint, and a ViewComponent for the search affordance, scoped to the list's `listable_class`.

## Acceptance Criteria
_To be expanded once the autocomplete approach is chosen._

## Agent Hand-Off
- Follow the patterns established by Part 2 and 02a; reuse the 02a `items#create` endpoint for the actual add.
- Do not duplicate the dashboard/show/edit surface from Part 2.

### Sub-Agent Plan
1. `codebase-analyzer` → determine the current per-domain search surface and whether a JSON autocomplete endpoint exists or must be added.
2. `codebase-pattern-finder` → find any existing autocomplete/typeahead Stimulus pattern in the app.
