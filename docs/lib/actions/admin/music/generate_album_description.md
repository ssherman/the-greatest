# Actions::Admin::Music::GenerateAlbumDescription

**Location:** `/web-app/app/lib/actions/admin/music/generate_album_description.rb`

**Namespace:** Actions::Admin::Music

**Inherits From:** Actions::Admin::BaseAction

**Purpose:** Custom admin action that queues background jobs to generate AI-powered descriptions for one or more albums.

## Overview

Bulk-capable action that triggers AI description generation for selected albums. Can be executed on a single album from the show page or on multiple albums from the index page. Jobs are queued to Sidekiq for asynchronous processing, allowing admins to continue working while descriptions are generated.

## Class Methods

### `.name`
Returns the display name for the action button.

**Returns:** `"Generate AI Description"`

### `.message`
Returns the instructional message shown in the action modal/form.

**Returns:** `"This will generate AI descriptions for the selected album(s) in the background."`

### `.confirm_button_label`
Returns the label for the confirmation button.

**Returns:** `"Generate Descriptions"`

### `.visible?(context = {})`
Determines if the action should be visible in the UI.

**Parameters:**
- `context` (Hash) - Contains view context information

**Returns:** `true` (visible in all contexts by default)

**Usage:** Shows on both individual album show pages and index page with bulk selection.

## Instance Methods

### `#call`
Queues AI description generation jobs for all selected albums.

**Expected Fields:** None (action requires no additional input)

**Expected Models:** One or more Music::Album instances

**Process:**
1. Extracts album IDs from models array
2. Iterates through each ID
3. Queues `Music::AlbumDescriptionJob` for each album
4. Returns success message with count

**Returns:**
- Always success: `ActionResult` with message "{count} album(s) queued for AI description generation."

**Side Effects:**
- Queues background jobs to Sidekiq
- Jobs will run asynchronously to generate/update album descriptions
- No immediate database changes (handled by background job)

**Edge Cases:**
- Empty models array: Returns "0 album(s) queued..." (harmless)
- Duplicate selections: Would queue duplicate jobs (UI prevents this)

## Background Job

**Job Class:** `Music::AlbumDescriptionJob`

**Job Execution:**
- Fetches album data (title, artists, release year, categories, etc.)
- Calls AI service to generate description
- Updates album.description field
- Handles errors gracefully without crashing

**Queue:** Default Sidekiq queue

**Retry:** Standard Sidekiq retry logic (25 retries over ~21 days)

## UI Integration

**Single Album (Show Page):**
- Appears as action button in actions dropdown/section
- Clicking opens simple confirmation modal
- No additional fields required
- Redirects back to album show page on success

**Bulk Selection (Index Page):**
- Appears in bulk actions dropdown
- Requires at least one album selected via checkboxes
- Submits to `bulk_action` endpoint with album_ids array
- Redirects back to index page on success

**Turbo Integration:**
- Form submitted via Turbo Stream
- Success: Updates flash message without full page reload
- Progress: No progress indicator (fire-and-forget operation)

## Dependencies

**Background Jobs:**
- `Music::AlbumDescriptionJob` - Performs actual AI description generation

**AI Services:**
- OpenAI API (via job) - Generates natural language descriptions

**Models:**
- `Music::Album` - Album records to generate descriptions for

## Security Considerations

**Rate Limiting:**
- No built-in rate limiting on action
- Could queue many expensive AI jobs if bulk-selected on large dataset
- Consider adding limit on bulk selections (e.g., max 50 at once)

**Cost Implications:**
- Each job makes API call to OpenAI (costs money)
- Admins should be aware of costs before bulk operations
- Consider adding cost estimate or warning in UI

**Authorization:**
- Inherits authorization from Admin::Music::AlbumsController
- Requires admin or editor role
- No additional permission checks

**Idempotency:**
- Safe to run multiple times on same album
- Job will overwrite existing description
- No data loss or corruption risk

## Testing

**Test File:** `test/lib/actions/admin/music/generate_album_description_test.rb`

**Coverage:**
- 4 unit tests
- 10 assertions
- 100% passing

**Test Categories:**
- Single album operation (1 test)
  - Queues one job
  - Returns "1 album(s)..." message
- Multiple album operation (1 test)
  - Queues multiple jobs
  - Returns correct count in message
- Message formatting (1 test)
  - Verifies count appears in message
- Edge cases (1 test)
  - Handles empty models array gracefully

**Testing Notes:**
- Uses Mocha to stub `Music::AlbumDescriptionJob.perform_async`
- Verifies job called with correct album IDs
- Does not test actual job execution (that's in job test)

## Common Gotchas

1. **Asynchronous Nature:** Description won't appear immediately after action succeeds - need to wait for job to complete
2. **Job Failures:** If job fails (API error, invalid data, etc.), no feedback to user unless they check job monitoring
3. **Overwriting:** Action doesn't check if album already has description - will overwrite existing content
4. **Empty Models:** Doesn't validate models.any? - returns success even with 0 albums (harmless but slightly confusing UX)

## Performance Considerations

**Bulk Operations:**
- 100 albums selected = 100 background jobs queued
- Each job makes 1 API call to OpenAI (~1-3 seconds per call)
- Sidekiq concurrency settings determine parallelism
- Could take several minutes for large batches

**Database Impact:**
- Minimal - only writes description field on job completion
- No N+1 queries or expensive operations in action itself

**API Rate Limits:**
- OpenAI has rate limits (requests per minute)
- Large bulk operations might hit limits
- Jobs will retry if rate-limited

## Related Documentation

- [Music::AlbumDescriptionJob](../../../jobs/music/album_description_job.md) - The background job that performs generation
- [Admin::Music::AlbumsController](../../../controllers/admin/music/albums_controller.md) - Controller that invokes this action
- [Actions::Admin::BaseAction](../base_action.md) - Parent class defining action pattern
- [Actions::Admin::Music::GenerateArtistDescription](generate_artist_description.md) - Similar action for artists

## Usage Examples

**Single Album:**
1. Admin views album show page
2. Clicks "Generate AI Description" button
3. Confirmation modal appears
4. Admin clicks "Generate Descriptions" button
5. Flash message: "1 album(s) queued for AI description generation."
6. Background job processes over next few seconds
7. Admin refreshes page to see new description

**Bulk Albums:**
1. Admin views albums index page
2. Selects 10 albums via checkboxes
3. Opens bulk actions dropdown
4. Selects "Generate AI Description"
5. Confirmation modal appears
6. Admin clicks "Generate Descriptions" button
7. Flash message: "10 album(s) queued for AI description generation."
8. Background jobs process over next minute
9. Descriptions gradually appear as jobs complete

## Future Enhancements

Potential improvements for this action:

1. **Progress Indicator:** Show real-time progress of background jobs in UI
2. **Validation:** Prevent action if album already has recent description
3. **Preview:** Show estimated cost before executing bulk operation
4. **Limit:** Enforce maximum bulk selection count (e.g., 50 albums max)
5. **Notification:** Email/notify admin when bulk operation completes
6. **Selective:** Add "Skip albums that already have descriptions" checkbox option

## Implementation History

- **Created:** 2025-11-09 (Phase 2)
- **Pattern Source:** Actions::Admin::Music::GenerateArtistDescription (Phase 1)
- **Last Updated:** 2025-11-09
