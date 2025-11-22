# [092] - Song Wizard: Step 4 - Review UI (Table & Filters)

## Status
- **Status**: Planned
- **Priority**: High
- **Created**: 2025-01-19
- **Part**: 7 of 10

## Overview
Build the review step UI: table with all items, status badges, filters, and bulk selection. The heavy UI work before actions.

## Acceptance Criteria
- [ ] Table shows all unverified items with columns: Status, Rank, Original, Matched, Source, Actions
- [ ] Status badges: ✓ Valid (green), ⚠ Invalid (red), ✗ Missing (gray)
- [ ] Row highlighting based on status
- [ ] Filters: Show all | Valid | Invalid | Missing
- [ ] Bulk selection with "Select all" checkbox
- [ ] Stats cards at top (Total, Valid %, Invalid %, Missing %)
- [ ] Pagination (50 items/page)
- [ ] Mobile responsive (horizontal scroll)

## Key Components

### View
**File**: `app/views/admin/music/songs/list_wizard/steps/_review.html.erb`
- Stats cards component
- Filter dropdown
- Bulk action bar (checkboxes, select all)
- Table (renders `_review_table.html.erb`)
- Navigation buttons

### Table Partial
**File**: `app/views/admin/music/songs/list_wizard/steps/_review_table.html.erb`
Renders item rows (Turbo Frame for refresh)

### Item Row Partial
**File**: `app/views/admin/music/songs/list_wizard/steps/_review_item_row.html.erb`
- Checkbox for bulk selection
- Status badge
- Original: title + artists
- Matched: song_name + mb_artist_names
- Source: OpenSearch (score) | MusicBrainz
- Actions dropdown (placeholder - full in [093])

### Stimulus Controller
**File**: `app/javascript/controllers/filter_controller.js`
Filter table rows by status (client-side)

**File**: `app/javascript/controllers/bulk_actions_controller.js`
Handle checkbox selection, select all

## Tests
- [ ] Table renders all items
- [ ] Filters work (show/hide rows)
- [ ] Select all checkbox works
- [ ] Stats accurate
- [ ] Pagination works
- [ ] Mobile responsive

## Related
- **Previous**: [091] Step 3: Validation
- **Next**: [093] Step 4: Actions
