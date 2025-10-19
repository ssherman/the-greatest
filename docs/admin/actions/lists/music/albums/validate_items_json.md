# Avo::Actions::Lists::Music::Albums::ValidateItemsJson

## Summary
Avo admin action that queues AI validation jobs for Music::Albums::List records. Validates that MusicBrainz matches in items_json are correct and flags invalid matches for review.

## Purpose
Provides admin interface for triggering AI validation of album matches after lists have been enriched with MusicBrainz data. Validates lists have required data before queueing background jobs.

## Action Configuration
- **Name**: "Validate items_json matches with AI"
- **Message**: "This will use AI to validate that MusicBrainz matches in items_json are correct. Invalid matches will be flagged in the data."
- **Confirm Button Label**: "Validate matches"

## Validation Requirements

Lists must meet these criteria to be validated:
1. **Type**: Must be `Music::Albums::List` instance
2. **items_json Present**: Must have populated items_json field
3. **Albums Array**: items_json must contain "albums" array
4. **Enriched Data**: At least one album must have `mb_release_group_id` (indicating MusicBrainz enrichment)

## Behavior

### Valid Lists
- Queues `Music::Albums::ValidateListItemsJsonJob` for each valid list
- Returns success message with count of queued jobs

### Invalid Lists
- Logs warning with list name, ID, and reason for skipping
- Excludes from job queue
- Continues processing remaining lists

### No Valid Lists
- Returns error message
- Does not queue any jobs

## Response Messages

### Success
```
2 list(s) queued for AI validation. Each list will be processed in a separate background job.
```

### Error (No Valid Lists)
```
No valid lists found. Lists must be Music::Albums::List with enriched items_json data.
```

## Logging

### Non-Album List
```
Skipping non-album list: Greatest Albums (ID: 123, Type: Books::List)
```

### Missing Enriched Data
```
Skipping list without enriched items_json: Rolling Stone Albums (ID: 456)
```

## Usage

### Single List
1. Navigate to Music::Albums::List show page
2. Click "Actions" dropdown
3. Select "Validate items_json matches with AI"
4. Confirm action
5. Check Sidekiq dashboard for job status

### Multiple Lists
1. Navigate to Music::Albums::List index page
2. Select multiple lists using checkboxes
3. Click "Actions" dropdown
4. Select "Validate items_json matches with AI"
5. Confirm action
6. Valid lists will be queued (invalid ones skipped)

## Dependencies
- `Music::Albums::List` - ActiveRecord model
- `Music::Albums::ValidateListItemsJsonJob` - Sidekiq job queued by this action
- Avo admin framework

## Related Classes
- `Music::Albums::ValidateListItemsJsonJob` - The job queued by this action
- `Services::Ai::Tasks::Lists::Music::Albums::ItemsJsonValidatorTask` - AI task that performs validation
- `Avo::Actions::Lists::Music::Albums::EnrichItemsJson` - Prerequisite action that adds MusicBrainz data

## Workflow Integration

Typical workflow:
1. Parse list HTML with AI → creates items_json with original data
2. **Enrich items_json** → adds MusicBrainz metadata to albums
3. **Validate items_json** (this action) → flags invalid matches with AI
4. View in items_json viewer → see enrichment status and invalid flags

## Registration
Registered in `Avo::Resources::MusicAlbumsList`:
```ruby
def actions
  super
  action Avo::Actions::Lists::ImportFromMusicbrainzSeries
  action Avo::Actions::Lists::Music::Albums::EnrichItemsJson
  action Avo::Actions::Lists::Music::Albums::ValidateItemsJson
end
```
