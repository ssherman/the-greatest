# [091] - Song Wizard: Step 3 - AI Validation

## Status
- **Status**: Planned
- **Priority**: High
- **Created**: 2025-01-19
- **Part**: 6 of 10

## Overview
Run AI validation on enriched items to flag bad matches (live vs studio, covers, etc.). Updates metadata with `ai_match_invalid: true` flag.

## Acceptance Criteria
- [ ] "Start Validation" button enqueues job
- [ ] Only validates items with mb_recording_id
- [ ] AI receives numbered list of Original→Matched pairs
- [ ] Invalid matches get `metadata["ai_match_invalid"] = true`
- [ ] Valid matches have flag removed (if previously invalid)
- [ ] Stats shown: Valid, Invalid, Total

## Key Components

### View
**File**: `app/views/admin/music/songs/list_wizard/steps/_validate.html.erb`
- Stats: Total validated, Valid count, Invalid count
- Progress bar
- Start/Re-run validation button

### Job
**File**: `app/sidekiq/music/songs/wizard_validate_list_items_job.rb`
Calls refactored validator service

### Service (Refactor Existing)
**File**: `app/lib/services/ai/tasks/lists/music/songs/items_json_validator_task.rb`
**Changes needed**:
- Read from `list.list_items.unverified` instead of `items_json["songs"]`
- Update each item's metadata with `ai_match_invalid` flag
- Return counts

**Contract**:
```ruby
# Input: List with enriched unverified items
# Output: Updates metadata on each item
# Returns: {valid_count:, invalid_count:, total_count:, reasoning:}
```

## Tests
- [ ] Job validates enriched items only
- [ ] AI flags invalid matches correctly
- [ ] Metadata updated with flags
- [ ] Stats accurate

## Related
- **Previous**: [090] Step 2: Enrich
- **Next**: [092] Step 4: Review UI
- **Reference**: `app/lib/services/ai/tasks/lists/music/songs/items_json_validator_task.rb`
