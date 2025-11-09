# Actions::Admin::Music::MergeAlbum

**Location:** `/web-app/app/lib/actions/admin/music/merge_album.rb`

**Namespace:** Actions::Admin::Music

**Inherits From:** Actions::Admin::BaseAction

**Purpose:** Custom admin action that merges a duplicate album into the target album, consolidating all associated data before deleting the source album.

## Overview

Single-record action that allows admins to merge duplicate albums in the music database. Takes a source album ID as input and merges all its data (list items, rankings, images, external links, etc.) into the current album, then deletes the source album. This is a destructive operation that cannot be undone.

## Class Methods

### `.name`
Returns the display name for the action button.

**Returns:** `"Merge Another Album Into This One"`

### `.message`
Returns the instructional message shown in the action modal/form.

**Returns:** Explanation that source album ID is required and source will be permanently deleted.

### `.confirm_button_label`
Returns the label for the confirmation button.

**Returns:** `"Merge Album"`

### `.visible?(context = {})`
Determines if the action should be visible in the UI.

**Parameters:**
- `context` (Hash) - Contains view context information

**Returns:** `true` if context[:view] == :show, `false` otherwise

**Usage:** Only shows on individual album show pages, not on index/list pages.

## Instance Methods

### `#call`
Executes the album merge operation with extensive validation.

**Expected Fields:**
- `source_album_id` (integer, required) - ID of the album to merge from
- `confirm_merge` (boolean/string, required) - Confirmation checkbox value

**Expected Models:** Single Music::Album instance (the target album)

**Validation Steps:**
1. Ensures exactly one album is selected (target)
2. Validates `source_album_id` field is present
3. Validates `confirm_merge` checkbox is checked (must be "1" or true, not "0")
4. Validates source album exists in database
5. Prevents self-merge (source ID ≠ target ID)

**Merge Process:**
- Delegates actual merge logic to `Music::Album::Merger` service
- Merger handles: list_items, ranked_items, images, external_links, releases, etc.
- Source album is deleted after successful merge

**Returns:**
- Success: `ActionResult` with message including both album titles and IDs
- Error: `ActionResult` with specific validation error message

**Possible Error Messages:**
- "This action can only be performed on a single album." - Multiple albums selected
- "Please enter the ID of the album to merge." - Missing source_album_id
- "Please confirm you understand this action cannot be undone." - Missing confirmation
- "Album with ID {id} not found." - Invalid source album ID
- "Cannot merge an album with itself. Please enter a different album ID." - Self-merge attempt
- "Failed to merge albums: {errors}" - Merger service returned errors

**Side Effects:**
- Moves all associations from source album to target album
- Permanently deletes source album record
- Cannot be undone

## Form Fields

The action requires two input fields in the UI:

**source_album_id:**
- Type: Number input
- Label: "Album ID to Merge"
- Required: Yes
- Validation: Must be existing album ID, cannot be same as target

**confirm_merge:**
- Type: Checkbox
- Label: "I understand this action cannot be undone"
- Required: Yes
- Validation: Must be checked

## UI Integration

**Visible In:**
- Admin::Music::AlbumsController#show page only
- Triggered via modal dialog using DaisyUI

**Turbo Frame:**
- Action form submitted via Turbo
- Success: Redirects to target album show page
- Error: Updates flash message in-place

**Modal Implementation:**
```erb
<dialog id="merge_album_modal" class="modal">
  <div class="modal-box">
    <%= form_with url: execute_action_admin_album_path(@album), method: :post do |form| %>
      <%= hidden_field_tag :action_name, "MergeAlbum" %>

      <div class="form-control">
        <%= label_tag :source_album_id, "Album ID to Merge", class: "label" %>
        <%= number_field_tag :source_album_id, nil, class: "input input-bordered", required: true %>
      </div>

      <div class="form-control">
        <%= check_box_tag :confirm_merge, "1", false, class: "checkbox" %>
        <%= label_tag :confirm_merge, "I understand this action cannot be undone" %>
      </div>

      <%= form.submit "Merge Album", class: "btn btn-primary" %>
    <% end %>
  </div>
</dialog>
```

## Dependencies

**Services:**
- `Music::Album::Merger` - Handles actual merge logic and data migration

**Models:**
- `Music::Album` - Target and source album records

**Background Jobs:**
- None (merge happens synchronously)

## Security Considerations

**Destructive Operation:**
- Cannot be undone once executed
- Requires explicit confirmation checkbox
- Only accessible to admin/editor users (enforced by controller)

**Validation:**
- Prevents self-merge which would cause data loss
- Validates source album exists before attempting merge
- Ensures single album selection to prevent confusion

**Authorization:**
- Inherits authorization from Admin::Music::AlbumsController
- Requires admin or editor role

## Testing

**Test File:** `test/lib/actions/admin/music/merge_album_test.rb`

**Coverage:**
- 7 unit tests
- 20 assertions
- 100% passing

**Test Categories:**
- Validation errors (6 tests)
  - Missing source_album_id
  - Missing confirmation (nil)
  - Unchecked confirmation checkbox (string "0")
  - Invalid source album ID
  - Self-merge attempt
  - Multiple album selection
- Successful merge (1 test)
  - Calls Merger service with correct params
  - Returns success message with album titles

**Testing Notes:**
- Uses Mocha to stub `Music::Album::Merger.call`
- Tests validation before hitting merger service
- Verifies correct parameters passed to merger

## Common Gotchas

1. **Field Access:** Must check both symbol and string keys for fields (`fields[:key] || fields["key"]`) due to form submission format variations
2. **Confirmation Checkbox:** Unchecked checkboxes post "0" string value, NOT nil/false. Must explicitly check for "1" or true to prevent destructive merge without confirmation.
3. **Error Handling:** Merger service returns result object, not exceptions, so check `result.success?`
4. **ID Comparison:** Use `.id` comparison to prevent type mismatches (integer vs string)

## Related Documentation

- [Music::Album::Merger](../../../services/music/album/merger.md) - The underlying merge service
- [Admin::Music::AlbumsController](../../../controllers/admin/music/albums_controller.md) - Controller that invokes this action
- [Actions::Admin::BaseAction](../base_action.md) - Parent class defining action pattern
- [Actions::Admin::Music::MergeArtist](merge_artist.md) - Similar merge action for artists

## Usage Example

From the album show page:

1. Admin clicks "Merge Another Album Into This One" button
2. Modal opens with form
3. Admin enters source album ID (e.g., 123)
4. Admin checks confirmation checkbox
5. Admin clicks "Merge Album" button
6. System validates inputs
7. System calls `Music::Album::Merger.call(source: album_123, target: current_album)`
8. System deletes source album
9. Page redirects to current album with success message
10. All data from album 123 now belongs to current album

## Implementation History

- **Created:** 2025-11-09 (Phase 2)
- **Pattern Source:** Actions::Admin::Music::MergeArtist (Phase 1)
- **Last Updated:** 2025-11-09
