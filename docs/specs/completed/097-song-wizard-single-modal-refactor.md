# 097 - Song Wizard Single Modal Refactor

## Status
- **Status**: Completed
- **Priority**: High
- **Created**: 2025-12-26
- **Started**: 2025-12-26
- **Completed**: 2025-12-27
- **Developer**: Claude

## Overview

Refactor the song wizard review step to use a single shared modal instead of rendering 3 modal components per list item. With 1000+ items, the current approach creates 3000+ modal DOM elements on page load, causing significant performance degradation. The new approach will use a single `<dialog>` element with a Turbo Frame that loads content on-demand when an action is clicked.

**Goal**: Reduce modal DOM elements from `3 * N items` to just `1`, dramatically improving initial page load and memory usage.

**Non-goals**:
- Changing the form submission flow or Turbo Stream responses
- Modifying the controller actions (they remain unchanged)
- Changing the visual design of modals

## Context & Links

- **Related tasks/phases**:
  - `095-song-wizard-polish.md` - Previous performance work (CSS filtering)
  - `092-song-step-4-review-ui.md` - Original review step implementation
  - `093-song-step-4-actions.md` - Modal action implementations
- **Feature doc**: `docs/features/list-wizard.md`
- **Source files (authoritative)**:
  - `app/components/admin/music/songs/wizard/review_step_component.rb`
  - `app/components/admin/music/songs/wizard/edit_metadata_modal_component.rb`
  - `app/components/admin/music/songs/wizard/link_song_modal_component.rb`
  - `app/components/admin/music/songs/wizard/search_musicbrainz_modal_component.rb`
  - `app/javascript/controllers/modal_form_controller.js`
  - `app/controllers/admin/music/songs/list_items_actions_controller.rb`
- **External docs (official)**:
  - [Turbo Handbook - Frames](https://turbo.hotwired.dev/handbook/frames)
  - [Turbo Reference - Frames](https://turbo.hotwired.dev/reference/frames)
  - [Stimulus Reference - Actions](https://stimulus.hotwired.dev/reference/actions)

## Interfaces & Contracts

### Domain Model (diffs only)

No database changes required.

### Endpoints

| Verb | Path | Purpose | Params/Body | Auth |
|---|---|---|---|---|
| GET | `/admin/songs/:list_id/items/:id/modal/:modal_type` | Load modal content | `modal_type`: `edit_metadata`, `link_song`, `search_musicbrainz` | admin |

> Existing action endpoints remain unchanged:
> - `POST /admin/songs/:list_id/items/:id/verify`
> - `PATCH /admin/songs/:list_id/items/:id/metadata`
> - `POST /admin/songs/:list_id/items/:id/manual_link`
> - `POST /admin/songs/:list_id/items/:id/link_musicbrainz`

### Schemas (JSON)

No JSON API changes.

### Behaviors (pre/postconditions)

**Current Behavior (Problem)**:
- `review_step_component.html.erb` loops through all items
- For each item, renders 3 modal ViewComponents inline
- Each modal has unique ID: `{modal_type}_modal_{item.id}_dialog`
- Inline `onclick` handlers call `showModal()` on the specific dialog
- With 1000 items: 3000 `<dialog>` elements in DOM

**New Behavior (Solution)**:

- Preconditions:
  - Single `<dialog>` element exists in review step (or layout)
  - Turbo Frame `id="modal_content"` inside dialog
  - Action buttons have `data-turbo-frame="modal_content"` and link to modal endpoint

- Postconditions/effects:
  - Clicking action button loads modal content via Turbo Frame
  - Modal opens automatically when content loads (Stimulus controller)
  - Form submission works exactly as before (same Turbo Stream responses)
  - Modal closes on successful submit or cancel click
  - Modal content cleared on close (ready for next use)

- Edge cases & failure modes:
  - Network error loading modal content: Show error in modal, allow retry
  - Form validation error: Re-render form with errors in modal frame
  - User clicks another action while modal open: Close current, load new content
  - ESC key: Close modal and clear content

### Non-Functionals

- **Performance budgets**:
  - Initial page load: Should reduce DOM element count by ~3000 for 1000-item lists
  - Modal open latency: ≤200ms to show modal shell, content loads async
  - Memory: Significant reduction (no pre-rendered modal elements)
- **No N+1**: Modal content endpoint must eager-load required associations
- **Responsiveness**: Modal should work on mobile (existing DaisyUI modal styling)

## Acceptance Criteria

- [x] Single `<dialog>` element used for all three modal types
- [x] Modal content loads on-demand when action button is clicked
- [x] Existing action buttons (`Edit Metadata`, `Link Existing Song`, `Search MusicBrainz`) work correctly
- [x] Form submissions return same Turbo Stream responses (item row + stats update)
- [x] Modal auto-closes on successful form submission
- [x] Modal closes on Cancel button click
- [x] Modal closes on ESC key press
- [x] Modal closes on backdrop click
- [x] Modal content is cleared when closed (no stale data)
- [x] Page with 1000+ items loads significantly faster (measurable improvement)
- [x] All existing review step tests pass
- [x] New tests added for modal loading endpoint

### Golden Examples

**Example 1: Edit Metadata Flow**
```text
Input: User clicks "Edit Metadata" on item #42
Steps:
  1. Button has href="/admin/songs/5/items/42/modal/edit_metadata"
     with data-turbo-frame="modal_content"
  2. Turbo fetches URL, replaces modal_content frame
  3. Stimulus controller detects turbo:frame-load, calls dialog.showModal()
  4. User edits JSON, clicks Save
  5. Form POSTs to existing /admin/songs/5/items/42/metadata
  6. Controller returns Turbo Stream (replace row, replace stats, append flash)
  7. modal_form_controller detects success, closes dialog, clears frame
Output: Item row updated, modal closed, flash shown
```

**Example 2: Cancel/Close Flow**
```text
Input: User clicks "Edit Metadata", then clicks Cancel
Steps:
  1. Modal opens with content loaded
  2. User clicks Cancel button
  3. Stimulus action calls dialog.close()
  4. Dialog close event clears turbo-frame innerHTML
Output: Modal closed, no changes made, ready for next modal
```

### Optional Reference Snippet (≤40 lines, non-authoritative)

```erb
<%# reference only - single modal structure %>
<%# Note: close event handled in JS to avoid conflicts with autoComplete.js %>
<dialog id="shared_modal" data-controller="shared-modal"
        data-action="turbo:frame-load->shared-modal#open">
  <div class="modal-box">
    <%= turbo_frame_tag "modal_content" do %>
      <%# Content loads here on-demand %>
    <% end %>
  </div>
  <form method="dialog" class="modal-backdrop">
    <button>close</button>
  </form>
</dialog>

<%# reference only - action button %>
<%= link_to "Edit Metadata",
    modal_admin_songs_list_item_path(@list, item, modal_type: :edit_metadata),
    data: { turbo_frame: "modal_content" },
    class: "dropdown-item" %>
```

```javascript
// reference only - shared modal controller
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    // Listen directly to avoid autoComplete.js close events bubbling up
    this.element.addEventListener('close', (e) => {
      if (e.target === this.element) this.clear()
    })
  }
  open() { this.element.showModal() }
  clear() { this.element.querySelector("turbo-frame").innerHTML = "" }
}
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture.
- Respect snippet budget (≤40 lines).
- Do not duplicate authoritative code; **link to file paths**.
- Preserve all existing functionality (form submissions, Turbo Streams, error handling).
- Use native HTML `<dialog>` element (already used by existing modals).
- Use DaisyUI modal classes for consistency.

### Required Outputs
- Updated files (paths listed in "Key Files Touched").
- Passing tests for the Acceptance Criteria.
- Updated sections: "Implementation Notes", "Deviations", "Documentation Updated".

### Sub-Agent Plan
1) codebase-pattern-finder → find existing Turbo Frame patterns in project
2) codebase-analyzer → verify modal form submission data flow preserved
3) technical-writer → update `docs/features/list-wizard.md` with new pattern

### Test Seed / Fixtures
- Existing fixtures: `music/songs/lists(:wizard_test_list)`, `music/songs/list_items(:*)`
- No new fixtures needed

---

## Implementation Notes (living)

### Approach

Implementation followed the planned approach with these details:

1. **Created SharedModalComponent** (`app/components/admin/music/songs/wizard/shared_modal_component.rb`)
   - Single `<dialog>` element with ID `shared_modal_dialog`
   - Contains Turbo Frame with ID `shared_modal_content`
   - Uses DaisyUI modal classes (`modal`, `modal-box`, `modal-backdrop`)
   - Constants exposed for consistent ID references across components

2. **Created shared_modal_controller.js** (`app/javascript/controllers/shared_modal_controller.js`)
   - `open()` action: Called on `turbo:frame-load` to show the dialog
   - `clear()` action: Called on `close` event to reset frame content to loading spinner
   - `close()` action: Programmatic close method for other controllers

3. **Created modal endpoint** in `ListItemsActionsController`
   - New `modal` action validates `modal_type` param
   - Renders appropriate partial from `modals/` subdirectory
   - Returns content wrapped in `turbo_frame_tag`

4. **Created modal content partials** in `app/views/admin/music/songs/list_items_actions/modals/`
   - `_edit_metadata.html.erb` - JSON metadata editor form
   - `_link_song.html.erb` - Song search/link form with autocomplete
   - `_search_musicbrainz.html.erb` - MusicBrainz search form (conditionally shows form or warning)
   - Each partial reuses the `modal-form` controller for auto-close on success

5. **Updated action buttons** in `review_step_component.html.erb` and `_item_row.html.erb`
   - Replaced `onclick` handlers with `link_to` helpers
   - Added `data-turbo-frame` pointing to shared modal frame ID
   - Kept popover hide behavior for smooth UX

6. **Updated error responses** in controller
   - All error Turbo Streams now target `SharedModalComponent::ERROR_ID`
   - Consistent error display in the shared modal

7. **Added helper methods** in `ListItemsActionsHelper`
   - `item_label(item)` - Formats item position and title for modal header
   - `formatted_metadata(item)` - Pretty-prints JSON for edit modal
   - `musicbrainz_available?(item)` - Checks if MB search can work

### Key Files Touched (paths only)
- `app/components/admin/music/songs/wizard/review_step_component.rb`
- `app/components/admin/music/songs/wizard/review_step_component.html.erb`
- `app/components/admin/music/songs/wizard/shared_modal_component.rb`
- `app/components/admin/music/songs/wizard/shared_modal_component.html.erb`
- `app/controllers/admin/music/songs/list_items_actions_controller.rb`
- `app/views/admin/music/songs/list_items_actions/modals/_edit_metadata.html.erb`
- `app/views/admin/music/songs/list_items_actions/modals/_link_song.html.erb`
- `app/views/admin/music/songs/list_items_actions/modals/_search_musicbrainz.html.erb`
- `app/views/admin/music/songs/list_items_actions/_item_row.html.erb`
- `app/helpers/admin/music/songs/list_items_actions_helper.rb`
- `app/javascript/controllers/shared_modal_controller.js`
- `config/routes.rb`
- `test/controllers/admin/music/songs/list_items_actions_controller_test.rb`

### Challenges & Resolutions
- **Error ID consistency**: Updated all controller error responses to use `SharedModalComponent::ERROR_ID` constant
- **Existing modal_form_controller**: Reused unchanged - each form partial specifies `modal_form_modal_id_value` pointing to shared modal ID
- **Helper method reuse**: Extracted common logic to `ListItemsActionsHelper` to avoid duplication between component and partials
- **ViewComponent helper access**: ViewComponent templates need `helpers.` prefix for Rails view helpers like `turbo_frame_tag`
- **autoComplete.js close event conflict**: The autoComplete.js library dispatches a `close` event when closing its dropdown, which bubbled up to the dialog and triggered our `clear()` action. Fixed by removing Stimulus action binding for `close` event and instead using a direct event listener that checks `event.target === this.element` to only respond to the dialog's own close event.

### Deviations From Plan
- Used `modals/` subdirectory instead of flat partials (cleaner organization)
- Kept loading spinner in modal template rather than separate partial
- Original modal components left in place for potential future removal
- Changed close event handling from Stimulus action (`close->shared-modal#clear`) to direct event listener with target check to avoid conflicts with autoComplete.js library's close events

## Acceptance Results
- **Date**: 2025-12-27
- **Verifier**: Claude (automated tests) + manual testing
- **Test Results**: 27 controller tests pass (5 new tests for modal endpoint)
- **Manual Testing**: Verified autocomplete selection works correctly in shared modal

## Future Improvements
- Consider extracting shared modal to application layout for reuse across admin
- Add loading indicator animation during content fetch
- Keyboard navigation improvements (focus trap)
- Delete unused per-item modal components after confirming production stability

## Related PRs
- TBD

## Documentation Updated
- [x] Class documentation in `SharedModalComponent` and `shared_modal_controller.js`
- [ ] `docs/features/list-wizard.md` - Update modal section (pending)
