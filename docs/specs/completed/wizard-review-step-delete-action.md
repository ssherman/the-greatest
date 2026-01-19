# Wizard Review Step Delete Action

## Status
- **Status**: Completed
- **Priority**: Medium
- **Created**: 2026-01-19
- **Started**: 2026-01-19
- **Completed**: 2026-01-19
- **Developer**: Claude

## Overview
Add a "Delete" action to the review step of the list wizard for both Songs and Albums. This allows users to remove individual list items directly from the wizard's review table without leaving the wizard context. The action will use a browser confirmation dialog before executing.

**Non-goals:**
- Bulk delete from review step (existing bulk_delete routes already exist for separate use)
- Custom modal confirmation (using simple browser confirm)

## Context & Links
- Related feature: List Wizard Infrastructure (`docs/features/list-wizard.md`)
- Shared concern: `app/controllers/concerns/list_items_actions.rb`
- Songs controller: `app/controllers/admin/music/songs/list_items_actions_controller.rb`
- Albums controller: `app/controllers/admin/music/albums/list_items_actions_controller.rb`
- Songs item_row partial: `app/views/admin/music/songs/list_items_actions/_item_row.html.erb`
- Albums item_row partial: `app/views/admin/music/albums/list_items_actions/_item_row.html.erb`
- Routes: `config/routes.rb` (lines 100-160)

## Interfaces & Contracts

### Domain Model (diffs only)
No model changes required. ListItem model already supports `destroy`.

### Endpoints
| Verb | Path | Purpose | Params/Body | Auth |
|---|---|---|---|---|
| DELETE | /admin/songs/lists/:list_id/items/:id | Delete single song list item | - | admin |
| DELETE | /admin/albums/lists/:list_id/items/:id | Delete single album list item | - | admin |

> Source of truth: `config/routes.rb`

### Turbo Stream Response Schema
```json
{
  "description": "Successful delete returns 3 Turbo Stream actions",
  "streams": [
    {
      "action": "remove",
      "target": "item_row_{item_id}"
    },
    {
      "action": "replace",
      "target": "review_stats_{list_id}",
      "content": "Re-rendered _review_stats partial"
    },
    {
      "action": "append",
      "target": "flash_messages",
      "content": "Success message partial"
    }
  ]
}
```

### Behaviors (pre/postconditions)

**Preconditions:**
- User must be authenticated admin
- List must exist and belong to correct type (Songs or Albums)
- ListItem must exist and belong to the list

**Postconditions:**
- ListItem is destroyed from database
- Item row is removed from DOM via Turbo Stream
- Review stats are recalculated and updated
- Flash success message is displayed
- Filter counts are updated via MutationObserver

**Edge cases & failure modes:**
- Item not found: Return 404 (standard Rails behavior)
- Item already deleted (race condition): Return 404
- Database constraint violation: Should not occur (list_items have no dependent records blocking deletion)

### Non-Functionals
- Performance: Single DELETE query, no N+1
- Security: Admin-only action (existing `Admin::Music::BaseController` auth)
- UX: Browser confirm dialog before deletion (data-turbo-confirm)

## Acceptance Criteria
- [ ] Delete action appears in item action popover menu for both Songs and Albums wizards
- [ ] Clicking "Delete" shows browser confirmation dialog ("Are you sure you want to delete this item?")
- [ ] Confirming deletion removes the item from database and DOM
- [ ] Review stats (total, valid, invalid, missing counts) are updated after deletion
- [ ] Filter counts are recalculated after deletion
- [ ] Success flash message is displayed
- [ ] Canceling confirmation does nothing
- [ ] Tests pass for both Songs and Albums delete actions

### Golden Examples

**Example 1: Successful deletion (Songs)**
```text
Input: DELETE /admin/songs/lists/5/items/123
       (with turbo-stream accept header)

Output: Turbo Stream response:
  - remove #item_row_123
  - replace #review_stats_5 with updated counts
  - append flash "Item deleted" to #flash_messages
```

**Example 2: Successful deletion (Albums)**
```text
Input: DELETE /admin/albums/lists/8/items/456

Output: Same pattern as songs
```

### Optional Reference Snippet (<=40 lines, non-authoritative)

Pattern for delete Turbo Stream response (reference only):
```ruby
# reference only - pattern from existing actions
def render_item_delete_success(message)
  respond_to do |format|
    format.turbo_stream do
      render turbo_stream: [
        turbo_stream.remove("item_row_#{@item.id}"),
        turbo_stream.replace("review_stats_#{@list.id}",
          partial: "review_stats", locals: {list: @list}),
        turbo_stream.append("flash_messages",
          partial: "flash_success", locals: {message: message})
      ]
    end
    format.html { redirect_to review_step_path, notice: message }
  end
end
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture.
- Use existing `ListItemsActions` concern pattern for shared logic.
- Respect snippet budget (<=40 lines).
- Do not duplicate authoritative code; **link to file paths**.

### Required Outputs
- Updated files (paths listed in "Key Files Touched").
- Passing tests demonstrating Acceptance Criteria.
- Updated: "Implementation Notes", "Deviations", "Documentation Updated".

### Sub-Agent Plan
1) codebase-pattern-finder -> verify action button pattern in item_row partials
2) codebase-analyzer -> confirm route structure and controller inheritance
3) technical-writer -> update list-wizard.md documentation

### Test Seed / Fixtures
- Existing test fixtures for songs/albums lists and list_items should be sufficient
- Test files:
  - `test/controllers/admin/music/songs/list_items_actions_controller_test.rb`
  - `test/controllers/admin/music/albums/list_items_actions_controller_test.rb`

---

## Implementation Notes (living)
- Approach taken: Added destroy action to the shared ListItemsActions concern, added `:destroy` to the base `item_actions_for_set_item` so both Songs and Albums controllers automatically inherit it via `super`. Used `turbo_stream.remove` instead of `replace` for the deleted row.
- Important decisions: Delete button is styled with `text-error` class and separated from other actions with a border-top divider for visual distinction.

### Key Files Touched (paths only)
- `app/controllers/concerns/list_items_actions.rb` - Added `destroy` action and `render_item_delete_success` helper, added `:destroy` to base `item_actions_for_set_item`
- `app/views/admin/music/songs/list_items_actions/_item_row.html.erb` - Added Delete button to popover (for Turbo Stream updates)
- `app/views/admin/music/albums/list_items_actions/_item_row.html.erb` - Added Delete button to popover (for Turbo Stream updates)
- `app/components/admin/music/songs/wizard/review_step_component.html.erb` - Added Delete button to inline popover menu
- `app/components/admin/music/songs/wizard/review_step_component.rb` - Added `destroy_path` helper method
- `app/components/admin/music/albums/wizard/review_step_component.html.erb` - Added Delete button to inline popover menu
- `app/components/admin/music/albums/wizard/review_step_component.rb` - Added `destroy_path` helper method
- `config/routes.rb` - Added `delete :destroy` to member routes for both songs and albums items
- `test/controllers/admin/music/songs/list_items_actions_controller_test.rb` - Added 3 destroy tests
- `test/controllers/admin/music/albums/list_items_actions_controller_test.rb` - Added 3 destroy tests
- `docs/features/list-wizard.md` - Updated Review Step Item Actions table

### Challenges & Resolutions
- Initial implementation only modified the partials, but the review step components render rows inline (partials are only used for Turbo Stream updates). Fixed by also adding the Delete button to the component templates.

### Deviations From Plan
- Did not need to modify the domain-specific controllers (Songs/Albums ListItemsActionsController) since they use `super` in `item_actions_for_set_item` and automatically inherit the base concern's `:destroy` action

## Acceptance Results
- Date: 2026-01-19
- Verifier: Automated tests (71 tests, 254 assertions, 0 failures)
- All destroy tests pass for both Songs and Albums controllers

## Future Improvements
- **Refactor item row to ViewComponent**: Create `Admin::Music::Songs::Wizard::ItemRowComponent` and `Admin::Music::Albums::Wizard::ItemRowComponent` (or a shared base) to eliminate duplication between the `_item_row.html.erb` partials and the inline rendering in `ReviewStepComponent` templates. Currently row rendering and action menus are duplicated in 4 places.
- Consider adding bulk delete UI with checkboxes if frequently needed
- Consider undo capability (soft delete) if deletion errors become common

## Related PRs
- #...

## Documentation Updated
- [x] `docs/features/list-wizard.md` - Added Delete to Review Step Item Actions table
- [x] Class docs - Not applicable (no new classes created)
