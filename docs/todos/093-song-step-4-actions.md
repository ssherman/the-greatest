# [093] - Song Wizard: Step 4 - Per-Item & Bulk Actions

## Status
- **Status**: Planned
- **Priority**: High
- **Created**: 2025-01-19
- **Part**: 8 of 10

## Overview
Implement all per-item and bulk actions for the review step. Users can verify, skip, edit, re-enrich, manually link, queue import, or delete items.

## Acceptance Criteria

### Per-Item Actions
- [ ] ✓ Verify - Links song, marks verified
- [ ] ✗ Skip - Marks skipped (deletable later)
- [ ] ✏️ Edit - Opens modal, edits metadata, triggers re-enrichment
- [ ] 🔍 Re-search - Re-runs enrichment for single item
- [ ] 🎯 Manual Link - Autocomplete to pick existing song
- [ ] ➕ Queue Import - Marks for MusicBrainz import
- [ ] 🗑️ Delete - Removes item immediately

### Bulk Actions
- [ ] Verify all selected
- [ ] Skip all selected
- [ ] Delete all selected

## Key Components

### Actions Controller
**File**: `app/controllers/admin/music/songs/list_items_actions_controller.rb`

**Endpoint Table**:
| Verb | Path | Action | Purpose |
|------|------|--------|---------|
| POST | /items/:id/verify | verify | Link song, mark verified |
| POST | /items/:id/skip | skip | Mark as skipped |
| PATCH | /items/:id/metadata | metadata | Update metadata, re-enrich |
| POST | /items/:id/re_enrich | re_enrich | Re-run enrichment |
| POST | /items/:id/manual_link | manual_link | Link to existing song |
| POST | /items/:id/queue_import | queue_import | Mark for import |
| DELETE | /items/:id | destroy | Delete item |
| POST | /items/bulk_verify | bulk_verify | Verify multiple |
| POST | /items/bulk_skip | bulk_skip | Skip multiple |
| DELETE | /items/bulk_delete | bulk_delete | Delete multiple |

### Services

**File**: `app/lib/services/lists/music/songs/item_verifier.rb`
```ruby
# Contract
def call(list_item:)
  # 1. Validate song_id exists in metadata
  # 2. Load song from DB
  # 3. Check for duplicates
  # 4. Update: listable = song, verified = true
  # Returns: Result.new(success?, data: {list_item:, song:})
end
```

**File**: `app/lib/services/lists/music/songs/bulk_verifier.rb`
```ruby
def call(list_id:, item_ids:)
  # Verify multiple items
  # Returns: {verified_count:, failed_count:, errors:[]}
end
```

### Modals

**Edit Modal**: `app/views/admin/music/songs/list_wizard/steps/_edit_item_modal.html.erb`
- Fields: title, artists (comma-separated), album, year
- Submit triggers metadata update + re-enrichment

**Manual Link Modal**: `app/views/admin/music/songs/list_wizard/steps/_manual_link_modal.html.erb`
- Autocomplete search for existing songs
- Submit links song immediately

## Tests
- [ ] Verify action links song
- [ ] Skip action marks item
- [ ] Edit updates metadata
- [ ] Re-enrich queues job
- [ ] Manual link works
- [ ] Queue import flags item
- [ ] Delete removes item
- [ ] Bulk actions work on selected items
- [ ] Turbo Stream updates table after action

## Related
- **Previous**: [092] Step 4: Review UI
- **Next**: [094] Step 5: Import
- **Reference**: Existing autocomplete in `app/components/autocomplete_component.rb`
