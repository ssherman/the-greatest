# Edit List Item — Autocomplete Item Association

## Status
- **Status**: Completed
- **Priority**: Medium
- **Created**: 2026-02-23
- **Started**: 2026-02-23
- **Completed**: 2026-02-24
- **Developer**: Claude

## Overview
Replace the read-only "Item cannot be changed" display in the **Edit List Item** modal with an autocomplete search field, allowing admins to associate (or re-associate) a list item with a game, album, or song. The autocomplete URL is determined by the parent list's STI type — the same pattern already used by `AddItemToListModalComponent`.

**Scope**: Games, Music Albums, Music Songs list items.
**Non-goals**: Movies/Books lists (no autocomplete search endpoints exist yet). Clearing an item association back to null.

## Context & Links
- Related: `AddItemToListModalComponent` already implements autocomplete for *creating* list items — this brings the same pattern to *editing*.
- Source files (authoritative):
  - `app/components/admin/edit_list_item_modal_component.rb`
  - `app/components/admin/edit_list_item_modal_component/edit_list_item_modal_component.html.erb`
  - `app/controllers/admin/list_items_controller.rb`
  - `app/components/admin/add_item_to_list_modal_component.rb` (pattern reference)
  - `app/components/autocomplete_component.rb` + `.html.erb`
  - `app/javascript/controllers/autocomplete_controller.js`

## Interfaces & Contracts

### Domain Model (diffs only)
No schema changes. The `list_items` table already has `listable_id` and `listable_type` columns.

### Endpoints

| Verb | Path | Purpose | Params/Body | Auth |
|---|---|---|---|---|
| PATCH | /admin/list_items/:id | Update list item (existing) | `list_item[listable_id]`, `list_item[position]`, `list_item[metadata]`, `list_item[verified]` | admin/editor/domain |

> The endpoint already exists. The only change is permitting `listable_id` in `update_list_item_params`.

Existing autocomplete search endpoints (no changes needed):

| Verb | Path | Purpose | Auth |
|---|---|---|---|
| GET | /admin/games/games/search?q= | Game autocomplete JSON | admin/editor/domain |
| GET | /admin/albums/search?q= | Album autocomplete JSON | admin/editor/domain |
| GET | /admin/songs/search?q= | Song autocomplete JSON | admin/editor/domain |

### Schemas (JSON)

Autocomplete response (existing, unchanged):
```json
[
  { "value": 123, "text": "Game Title (2023)" }
]
```

### Behaviors (pre/postconditions)

**Preconditions:**
- List item exists and belongs to a list with STI type `Games::List`, `Music::Albums::List`, or `Music::Songs::List`.
- The selected autocomplete result must be a valid record of the expected listable type.

**Postconditions/effects:**
- `list_item.listable_id` is updated to the selected item's ID.
- `list_item.listable_type` remains unchanged (already set correctly for the list type, or set if previously null).
- `list_item.verified` is set to `true` when a new item is selected via autocomplete (auto-verify on explicit selection).
- The list items table re-renders via Turbo Stream (existing behavior).

**Edge cases & failure modes:**
- **Duplicate item**: If the selected item is already in the list, the existing uniqueness validation fires and displays "is already in this list" as a flash error.
- **No selection made**: If the autocomplete field is left empty (no hidden field value), the `listable_id` param is blank and the existing `listable_id` is preserved (no change). The form still submits other field changes normally.
- **Unlinked item (listable_id is null)**: The autocomplete field starts blank (same as any other item). Selecting an item links it for the first time. `listable_type` must be set from the list's expected type if not already present.

### Non-Functionals
- No new queries beyond the existing autocomplete search endpoints.
- No N+1 changes — the list items index already eager-loads `:listable`.
- Autocomplete debounce: 300ms (existing default in `autocomplete_controller.js`).

## Acceptance Criteria
- [x] Edit modal for games list items shows an autocomplete search field instead of "Item cannot be changed".
- [x] Edit modal for music album list items shows album autocomplete.
- [x] Edit modal for music song list items shows song autocomplete.
- [x] Autocomplete field starts blank with the current item name shown as a label above.
- [x] Selecting an autocomplete result updates `listable_id` on save and auto-sets `verified: true`.
- [x] If no autocomplete selection is made, `listable_id` is unchanged on save.
- [x] Attempting to associate a duplicate item shows a validation error flash message.
- [x] `listable_type` is correctly set when associating a previously unlinked item.
- [x] Position, metadata, and verified fields continue to work as before.
- [x] Turbo Stream response correctly re-renders the list items table after update.

### Golden Examples

```text
Input: Admin edits list item #42 on a Games::List. Current listable is "Halo 3" (id: 10).
       Admin searches "Half", selects "Half-Life 2 (2004)" (id: 25), submits.
Output: list_item #42 now has listable_id=25, listable_type="Games::Game", verified=true.
        Flash: "Item updated successfully."
        List items table re-renders showing "Half-Life 2" at the item's position.

Input: Admin edits list item #7 on a Music::Albums::List. listable_id is null (unlinked).
       Admin searches "Abbey", selects "Abbey Road - The Beatles" (id: 99), submits.
Output: list_item #7 now has listable_id=99, listable_type="Music::Album", verified=true.
        Flash: "Item updated successfully."
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture.
- Respect snippet budget (≤40 lines).
- Do not duplicate authoritative code; **link to file paths**.
- Reuse `AutocompleteComponent` and the existing `autocomplete_url` / `expected_listable_type` dispatch pattern from `AddItemToListModalComponent`.

### Required Outputs
- Updated files (paths listed in "Key Files Touched").
- Passing tests demonstrating Acceptance Criteria.
- Updated: "Implementation Notes", "Deviations", "Documentation Updated".

### Sub-Agent Plan
1) codebase-pattern-finder → confirm `AddItemToListModalComponent` autocomplete pattern for reuse
2) codebase-analyzer → verify `update_list_item_params` and Turbo Stream response handling
3) technical-writer → update docs and cross-refs

### Test Seed / Fixtures
- Existing list and list_item fixtures should suffice.
- Tests need: a `Games::List` with a `ListItem` (linked and unlinked), a `Games::Game` to select via autocomplete.

---

## Implementation Notes (living)

### Approach (recommended)

**1. `EditListItemModalComponent` (Ruby class)**
- Add `autocomplete_url` method — same `case list.class.name` dispatch as `AddItemToListModalComponent#autocomplete_url`.
- Add `expected_listable_type` method — same pattern.
- Add `item_label` method — same pattern.

**2. `EditListItemModalComponent` (HTML template)**
- Replace the read-only item display div with:
  - A label showing the current item name (via `item_display_name`).
  - An `AutocompleteComponent` wired to the autocomplete URL, with `name: "list_item[listable_id]"`.
  - A hidden field for `listable_type` (set to `expected_listable_type`), included only when listable_type is currently blank.
- Keep position, metadata, and verified fields unchanged.

**3. `ListItemsController#update_list_item_params`**
- Permit `listable_id` in addition to existing params: `:listable_id, :position, :metadata, :verified`.

**4. Auto-verify behavior**
- Option A: Handle in the controller `update` action — if `listable_id` changed, set `verified: true`.
- Option B: Handle client-side — when autocomplete selection is made, check the verified checkbox via a Stimulus action. (Simpler, no controller change needed.)
- Recommended: Option A (server-side) for reliability.

### Key Files Touched (paths only)
- `app/components/admin/edit_list_item_modal_component.rb`
- `app/components/admin/edit_list_item_modal_component/edit_list_item_modal_component.html.erb`
- `app/controllers/admin/list_items_controller.rb`
- `test/controllers/admin/list_items_controller_test.rb` (or integration test)

### Challenges & Resolutions
- The unique index on `(list_id, listable_type, listable_id)` will catch duplicates at the DB level. The model validation `validates :listable_id, uniqueness: {scope: [:list_id, :listable_type]}` provides a user-friendly message.
- When an unlinked item (null `listable_type`) gets a new association, both `listable_id` AND `listable_type` need to be set. The hidden field for `listable_type` handles this.

### Deviations From Plan
- `listable_type` is set server-side in the controller (based on list STI type) rather than via a hidden field in the form. Simpler — no need to permit `listable_type` in update params.
- No `expected_listable_type` method on the component; the controller handles it via `expected_listable_type_for(list)`.

## Acceptance Results
- **Date**: 2026-02-24
- **Verifier**: Automated tests (35/35 controller tests, 9/9 component tests, 964/964 admin tests pass)

## Future Improvements
- Add autocomplete support for Movies and Books lists when search endpoints are built.
- Consider filtering out already-linked items from autocomplete results to prevent duplicate selection attempts.

## Related PRs
- #…

## Documentation Updated
- [x] Spec marked complete
- [ ] `documentation.md`
- [ ] Class docs
