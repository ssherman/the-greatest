# 107 - Bulk Delete All List Items from Admin List Show Page

## Status
- **Status**: Completed
- **Priority**: Medium
- **Created**: 2026-01-01
- **Started**: 2026-01-01
- **Completed**: 2026-01-01
- **Developer**: Claude

## Overview
Add a "Delete All Items" button to the custom admin list show page that allows admins to remove all list_items from a list in a single action. Currently this operation requires Rails console access. The action must be transactional (all-or-nothing) and require explicit user confirmation before executing.

**Scope**: Custom admin UI only (not Avo). Generic implementation that works for any List type (albums, songs, and future domains).

**Non-goals**:
- No partial deletion (selecting specific items)
- No soft-delete functionality
- No undo capability

## Context & Links
- Related tasks/phases: Part of ongoing custom admin UI development
- Source files (authoritative):
  - `app/controllers/admin/list_items_controller.rb` - Generic list items controller
  - `app/views/admin/music/albums/lists/show.html.erb` - Album list show view
  - `app/views/admin/music/songs/lists/show.html.erb` - Song list show view
  - `config/routes.rb:225-231` - Generic admin list routes
- Model documentation:
  - `docs/models/list.md` - List model (has_many :list_items, dependent: :destroy)
  - `docs/models/list_item.md` - ListItem model

## Interfaces & Contracts

### Domain Model (diffs only)
No database changes required. Uses existing `list.list_items.destroy_all` functionality.

### Endpoints
| Verb | Path | Purpose | Params/Body | Auth |
|------|------|---------|-------------|------|
| DELETE | /admin/list/:list_id/list_items/destroy_all | Delete all list_items for any list | None | admin |

> Source of truth: `config/routes.rb`

### Schemas (JSON)
N/A - Standard HTML request/response with redirect

### Behaviors (pre/postconditions)

**Preconditions:**
- User must be authenticated as admin
- List must exist (returns 404 if not found)
- List may have zero or more list_items

**Postconditions/effects:**
- All list_items associated with the list are permanently deleted
- The list itself remains unchanged
- User is redirected back to list show page
- Flash notice displays count of deleted items

**Edge cases & failure modes:**
- List has zero items: Action succeeds with "0 items deleted" message
- Database error during deletion: Transaction rolls back, no items deleted, error flash shown
- List not found: Returns 404 (standard Rails behavior)
- Concurrent deletion: Transaction isolation handles this safely

### Non-Functionals
- **Performance**: Single DELETE query with transaction, no N+1 concerns
- **Security**: Requires admin authentication (inherited from `Admin::BaseController`)
- **UX**: Native browser confirmation dialog via Turbo (`data-turbo-confirm`)

## Acceptance Criteria
- [x] "Delete All Items" button appears on list show pages in the items card header (next to "+ Add" button)
- [x] Button is styled as `btn btn-error btn-outline btn-sm` to indicate destructive action
- [x] Clicking button shows browser confirmation dialog: "Are you sure you want to delete all X items from this list? This cannot be undone."
- [x] Confirmation dialog shows actual item count (not generic message)
- [x] Confirming deletion removes all list_items in a single transaction
- [x] After deletion, user is redirected to list show page with flash notice: "X items deleted from list."
- [x] If deletion fails, user sees error flash and no items are deleted
- [x] Button is hidden when list has zero items
- [x] Turbo frame for list_items refreshes after deletion to show empty state

### Golden Examples

**Example 1: Successful deletion**
```text
Input: Admin clicks "Delete All Items" on list with 50 items, confirms dialog
Output:
  - All 50 list_items deleted from database
  - Redirect to show page
  - Flash: "50 items deleted from list."
  - List items section shows empty state
```

**Example 2: Empty list**
```text
Input: Admin views list show page for list with 0 items
Output:
  - Button is disabled or hidden
  - No action possible
```

**Example 3: Database failure (edge case)**
```text
Input: Database constraint violation during deletion
Output:
  - Transaction rolled back
  - No items deleted
  - Redirect to show page
  - Flash error: "Failed to delete items: [error message]"
```

### Optional Reference Snippet (<=40 lines, non-authoritative)
```ruby
# reference only - add to app/controllers/admin/list_items_controller.rb
def destroy_all
  deleted_count = 0

  ActiveRecord::Base.transaction do
    deleted_count = @list.list_items.destroy_all.count
  end

  redirect_back fallback_location: root_path, notice: "#{deleted_count} items deleted from list."
rescue ActiveRecord::RecordNotDestroyed => e
  redirect_back fallback_location: root_path, alert: "Failed to delete items: #{e.message}"
end
```

```erb
<%# reference only - button placement in show.html.erb %>
<div class="flex gap-2">
  <% if @list.list_items.any? %>
    <%= button_to destroy_all_admin_list_list_items_path(@list),
        method: :delete,
        class: "btn btn-error btn-outline btn-sm",
        data: { turbo_confirm: "Are you sure you want to delete all #{@list.list_items.count} items? This cannot be undone." } do %>
      Delete All Items
    <% end %>
  <% end %>
  <button class="btn btn-primary btn-sm" onclick="...">+ Add Album</button>
</div>
```

```ruby
# reference only - route addition to config/routes.rb
scope "list/:list_id", as: "list" do
  resources :list_penalties, only: [:index, :create]
  resources :list_items, only: [:index, :create] do
    collection do
      delete :destroy_all
    end
  end
end
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture.
- Respect snippet budget (<=40 lines).
- Do not duplicate authoritative code; **link to file paths**.
- Use existing controller inheritance pattern (`Admin::Music::ListsController`).
- Use existing confirmation pattern (`data-turbo-confirm`).

### Required Outputs
- Updated files (paths listed in "Key Files Touched").
- Passing tests demonstrating Acceptance Criteria.
- Updated: "Implementation Notes", "Deviations", "Documentation Updated".

### Sub-Agent Plan
1) codebase-pattern-finder -> Already completed - found existing `bulk_delete` pattern in `list_items_actions_controller.rb:221-226`
2) codebase-analyzer -> Already completed - understood controller structure and view layout
3) technical-writer -> Update docs after implementation

### Test Seed / Fixtures
- Use existing `test/fixtures/lists.yml` fixtures
- Use existing `test/fixtures/list_items.yml` fixtures
- Test file: `test/controllers/admin/list_items_controller_test.rb` (extend existing)

---

## Implementation Notes (living)
- Approach taken: Added `destroy_all` action to the generic `Admin::ListItemsController` rather than domain-specific controllers, ensuring the feature works for all list types (albums, songs, and future domains).
- Important decisions: Used the existing `redirect_path` helper to redirect to the correct list show page based on list type, maintaining consistency with other controller actions.

### Key Files Touched (paths only)
- `app/controllers/admin/list_items_controller.rb` - Added `destroy_all` action with transaction wrapping
- `app/views/admin/music/albums/lists/show.html.erb` - Added "Delete All Items" button to items card header
- `app/views/admin/music/songs/lists/show.html.erb` - Added "Delete All Items" button to items card header
- `config/routes.rb` - Added `destroy_all` collection route under the generic list/list_items scope (lines 227-231)
- `test/controllers/admin/list_items_controller_test.rb` - Added 4 tests: album list deletion, song list deletion, empty list handling, admin authorization

### Challenges & Resolutions
- None encountered. Implementation followed existing patterns in the codebase.

### Deviations From Plan
- None. Implementation followed the spec exactly.

## Acceptance Results
- Date: 2026-01-01
- Verifier: Claude
- All 21 tests pass in `test/controllers/admin/list_items_controller_test.rb`

## Future Improvements
- Consider adding bulk delete for other list types (Books, Movies, Games) when custom admin is built for those domains
- Consider adding a "Confirm by typing list name" pattern for extra safety on large lists

## Related PRs
- Pending commit

## Documentation Updated
- [x] Spec file updated with implementation notes
- [x] No class docs needed - controller action follows existing patterns
