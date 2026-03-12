# Admin Lists — Clear All Positions

## Status
- **Status**: Completed
- **Priority**: Medium
- **Created**: 2026-03-11
- **Started**: 2026-03-11
- **Completed**: 2026-03-11
- **Developer**: AI Agent

## Overview
Add a "Delete All Positions" button to the admin lists show page (next to "Delete All Items") that resets all `list_item.position` values to `nil` for a given list. This addresses the problem where the list import wizard assumes every list is ranked, but many lists are unranked. The action is shared across all list domains (music albums, music songs, games, movies, books).

**Non-goals**: This does not re-rank, reorder, or reassign positions — it only clears them to `nil`.

## Context & Links
- Related: List import wizard sets `position: rank` during import (`items_json_importer.rb`)
- Source files (authoritative):
  - `app/controllers/admin/list_items_controller.rb` — shared list item actions including `destroy_all` and `clear_positions`
  - `app/components/admin/lists/show_component.html.erb` — show page with action buttons
  - `app/models/list_item.rb` — `position` integer column, `allow_blank: true`
  - `config/routes.rb` — collection routes under `list/:list_id/list_items`

## Interfaces & Contracts

### Domain Model (diffs only)
- No schema changes. `list_items.position` is already a nullable integer.

### Endpoints
| Verb | Path | Purpose | Params/Body | Auth |
|---|---|---|---|---|
| DELETE | /admin/list/:list_id/list_items/clear_positions | Reset all positions to nil for list | — | admin |

> Source of truth: `config/routes.rb`

### Behaviors (pre/postconditions)
- **Precondition**: List must exist; user must be authorized admin/editor.
- **Postcondition**: All `list_items` for the given list have `position = NULL`. No items are created or destroyed.
- **Edge cases**:
  - List has no items → action succeeds, redirects with "Positions cleared for 0 items." notice.
  - All items already have `nil` position → action succeeds, `update_all` returns total row count regardless.
- **Failure modes**: Standard ActiveRecord errors redirect with alert.

### Non-Functionals
- Single `UPDATE list_items SET position = NULL WHERE list_id = ?` query — no N+1, no per-record callbacks needed.
- Admin-only access (existing `before_action :authenticate_admin!` on `ListItemsController`).

## Acceptance Criteria
- [x] "Delete All Positions" button appears on admin list show page next to "Delete All Items" button, only when list has items.
- [x] Clicking the button shows a confirmation dialog (turbo_confirm) stating the count of items affected.
- [x] On confirm, all `list_items.position` values for that list are set to `nil`.
- [x] User is redirected back to the list show page with a notice like "Positions cleared for N items."
- [x] The action works for all list domains (music albums, music songs, games, movies, books).
- [x] Button uses warning styling (`btn btn-warning btn-outline btn-sm`) to differentiate from the error-styled "Delete All Items".
- [x] Integration tests cover happy path, empty list, cross-domain (songs), and auth denial.

### Golden Examples
```text
Input: DELETE /admin/list/42/list_items/clear_positions
  List 42 has 15 items with positions [1, 2, 3, ..., 15]

Output: Redirect to list show page
  Flash notice: "Positions cleared for 15 items."
  All 15 list_items now have position = nil
```

```text
Input: DELETE /admin/list/99/list_items/clear_positions
  List 99 has 5 items, all with position = nil already

Output: Redirect to list show page
  Flash notice: "Positions cleared for 5 items."
  No change to data (idempotent)
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture.
- Mirror the `destroy_all` pattern exactly (route, controller action, view button, confirmation dialog).
- Respect snippet budget (≤40 lines).
- Do not duplicate authoritative code; **link to file paths**.

### Required Outputs
- Updated files (paths listed in "Key Files Touched").
- Passing tests demonstrating Acceptance Criteria.
- Updated: "Implementation Notes", "Deviations", "Documentation Updated".

### Sub-Agent Plan
1) codebase-pattern-finder → confirm `destroy_all` pattern for modeling
2) codebase-analyzer → verify route nesting and auth flow
3) technical-writer → update docs and cross-refs

### Test Seed / Fixtures
- Used existing `lists(:music_albums_list)`, `lists(:music_songs_list)`, `music_albums(:dark_side_of_the_moon)`, `music_albums(:abbey_road)`, `music_songs(:time)`, `music_songs(:money)` fixtures.

---

## Implementation Notes (living)
- Approach taken: Mirrored the existing `destroy_all` pattern exactly — same route style (collection DELETE), same controller structure, same view button placement and styling conventions.
- Important decisions:
  - Used `update_all(position: nil)` for a single efficient SQL UPDATE rather than iterating records.
  - Placed "Delete All Positions" button before "Delete All Items" since it's the less destructive action.
  - Used `btn-warning` styling to visually distinguish from the `btn-error` "Delete All Items" button.

### Key Files Touched (paths only)
- `config/routes.rb`
- `app/controllers/admin/list_items_controller.rb`
- `app/components/admin/lists/show_component.html.erb`
- `test/controllers/admin/list_items_controller_test.rb`

### Challenges & Resolutions
- Auth test initially failed because `@album_list.list_items.first` returned nil after the unauthorized redirect (items collection was cleared in setup). Fixed by capturing the item in a local variable before the request.

### Deviations From Plan
- None. Implementation followed the spec exactly.

## Acceptance Results
- **Date**: 2026-03-11
- **Verifier**: AI Agent
- **Artifacts**: All 39 tests pass in `test/controllers/admin/list_items_controller_test.rb` (4 new tests added: happy path, empty list, song list cross-domain, auth denial).

## Future Improvements
- Could add a "Re-rank" action that assigns sequential positions based on current order.
- Could add position status indicator on list show page (e.g., "15/15 ranked" or "0/15 ranked").

## Related PRs
-

## Documentation Updated
- [x] Spec file completed and moved to `docs/specs/completed/`
- [ ] Class docs (no new classes introduced)
