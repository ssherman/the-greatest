# Avo::Actions::Lists::Music::Songs::ValidateItemsJson

## Summary
Avo admin action that queues AI validation jobs for selected Music::Songs::List records. Validates that MusicBrainz recording matches in items_json are correct, flagging invalid matches for review.

## Purpose
Allows admins to:
- Trigger AI validation for one or more song lists
- Identify incorrect MusicBrainz matches (live vs studio, covers, remixes)
- Flag problematic matches before importing songs
- Re-validate lists after enrichment improvements

## Location
`app/avo/actions/lists/music/songs/validate_items_json.rb`

## Parent Class
- Inherits from `Avo::BaseAction`

## Configuration

### Class Attributes
- **name** - "Validate items_json matches with AI"
- **message** - "This will use AI to validate that MusicBrainz matches in items_json are correct. Invalid matches will be flagged in the data."
- **confirm_button_label** - "Validate matches"

## Public Methods

### `#handle(query:, fields:, current_user:, resource:, **args)`
Validates selected lists and queues validation jobs.

**Parameters**:
- `query` - ActiveRecord::Relation of selected records
- `fields` - Hash of field values (unused)
- `current_user` - Current admin user (unused)
- `resource` - Avo resource class (unused)
- `**args` - Additional arguments (unused)

**Process**:
1. Load all record IDs (triggers query execution)
2. Filter to valid lists:
   - Must be `Music::Songs::List` type
   - Must have items_json with songs array
   - Must have at least one enriched song (mb_recording_id present)
3. Log warnings for skipped lists
4. Return error if no valid lists found
5. Queue validation job for each valid list
6. Return success message with count

**Returns**:
- `error(message)` - If no valid lists found
- `succeed(message)` - With count of queued jobs

## Validation Logic

### List Type Check
```ruby
is_song_list = list.is_a?(::Music::Songs::List)
```
Ensures record is correct type (not album list, book list, etc.).

### Enriched Items Check
```ruby
has_enriched_items = list.items_json.present? &&
  list.items_json["songs"].is_a?(Array) &&
  list.items_json["songs"].any? { |s| s["mb_recording_id"].present? }
```

Verifies:
- items_json field exists
- "songs" key contains array
- At least one song has MusicBrainz recording ID

**Rationale**: Cannot validate matches that don't exist. Enrichment must happen first.

### Warning Logging
Logs warnings for skipped lists to aid debugging:
```ruby
Rails.logger.warn "Skipping non-song list: #{list.name} (ID: #{list.id}, Type: #{list.class})"
Rails.logger.warn "Skipping list without enriched items_json: #{list.name} (ID: #{list.id})"
```

## Error Messages

### No Valid Lists
```
"No valid lists found. Lists must be Music::Songs::List with enriched items_json data."
```

Returned when:
- All selected lists are wrong type
- All selected lists lack enriched data
- No lists selected

## Success Message
```
"#{valid_lists.length} list(s) queued for AI validation. Each list will be processed in a separate background job."
```

Informs admin:
- How many jobs were queued
- That processing is asynchronous
- Each list gets separate job

## Usage

### From List Index Page
1. Admin selects one or more song lists
2. Clicks "Actions" dropdown
3. Selects "Validate items_json matches with AI"
4. Confirms action
5. Jobs queued, success message shown
6. Admin can view Sidekiq dashboard for progress

### From List Show Page
1. Admin views single song list
2. Clicks "Actions" button
3. Selects "Validate items_json matches with AI"
4. Confirms action
5. Job queued, success message shown

## Data Flow

1. **Admin** - Selects lists and triggers action
2. **This Action** - Validates lists, queues jobs
3. **Sidekiq** - Picks up jobs from default queue
4. **Background Job** - Invokes AI validation task
5. **AI Task** - Updates items_json with flags
6. **Database** - items_json updated
7. **Admin** - Refreshes viewer to see flagged songs

## Related Components
- **Background Job** - `Music::Songs::ValidateListItemsJsonJob` (performs validation)
- **AI Task** - `Services::Ai::Tasks::Lists::Music::Songs::ItemsJsonValidatorTask` (AI logic)
- **Viewer Tool** - `Avo::ResourceTools::Lists::Music::Songs::ItemsJsonViewer` (displays results)
- **Enrichment Action** - `Avo::Actions::Lists::Music::Songs::EnrichItemsJson` (must run first)

## Registration
Registered in `Avo::Resources::MusicSongsList`:
```ruby
def actions
  super
  action Avo::Actions::Lists::ImportFromMusicbrainzSeries
  action Avo::Actions::Lists::Music::Songs::EnrichItemsJson
  action Avo::Actions::Lists::Music::Songs::ValidateItemsJson
end
```

## Testing
No automated tests per project policy. Avo actions are admin UI components tested manually.

**Manual Test Checklist**:
- ✅ Action appears in Music::Songs::List actions menu
- ✅ Confirmation dialog shows correct message
- ✅ Success for list with enriched items_json
- ✅ Error for list without enriched data
- ✅ Error for wrong list type (album list)
- ✅ Multiple lists queued correctly
- ✅ Jobs appear in Sidekiq dashboard
- ✅ Warning logs for skipped lists

## Workflow Integration

### Typical Admin Workflow
1. Create song list (manually or via MusicBrainz import)
2. Run "Enrich items_json" action (task 064)
3. View enriched data in Items JSON Viewer
4. Run "Validate items_json matches with AI" (this action)
5. Wait for background job completion
6. Refresh and view flagged matches in Items JSON Viewer
7. Review flagged songs (red background)
8. Re-run enrichment or validation if needed
9. Import songs from items_json (future task)

### Re-validation Support
Action can be run multiple times on same list:
- Previous ai_match_invalid flags are removed for valid matches
- New flags added for newly identified invalid matches
- Supports iterative refinement of matching

## Pattern Source
Based on `Avo::Actions::Lists::Music::Albums::ValidateItemsJson` (task 054) with adaptations for songs (mb_recording_id vs mb_release_group_id).

## Performance
- Lightweight validation (type checks, array checks)
- No AI calls in action itself (queued for background)
- Fast response to admin (< 100ms)
- Parallel job processing via Sidekiq
