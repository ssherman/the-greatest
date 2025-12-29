# Music::Albums::WizardImportAlbumsJob

## Summary
Background job that imports albums from MusicBrainz into the database and links them to ListItems. Part of the album list wizard Step 6 (Import). Supports two import paths: `custom_html` (item-by-item import from parsed HTML) and `musicbrainz_series` (currently falls back to item-by-item processing).

## Location
`app/sidekiq/music/albums/wizard_import_albums_job.rb`

## Interface

### `perform(list_id)`
Imports albums for all eligible list items in the given list.

**Parameters:**
- `list_id` (Integer) - ID of the `Music::Albums::List` to process

**Side Effects:**
- Updates `wizard_state` with progress and stats
- Creates `Music::Album` records via DataImporters::Music::Album::Importer
- Sets `list_items.listable_id` to imported album
- Sets `list_items.verified` to true on success
- Updates `list_items.metadata` with import timestamps and errors

## Workflow

1. Find list by ID
2. Read `import_source` from wizard_state
3. Dispatch to appropriate import method (series or custom_html)
4. Update wizard_state step status to "running" with progress 0
5. Query items needing import (has `mb_release_group_id`, no `listable_id`)
6. Iterate through eligible items:
   - Call `DataImporters::Music::Album::Importer.call(release_group_musicbrainz_id: mbid)`
   - On success: link album to item, mark verified, record import timestamp
   - On failure: store error in metadata, continue with next item
   - Update progress periodically
7. Update wizard_state step status to "completed" with final stats

## Progress Updates

Progress is updated via `wizard_manager.update_step_status!`:
- Every 10 items processed (`PROGRESS_UPDATE_INTERVAL`)
- Every 5 seconds (whichever comes first)
- Always at start (0%) and end (100%)

**Metadata tracked:**
```ruby
{
  "import_source" => "custom_html",
  "processed_items" => 45,
  "total_items" => 50,
  "imported_count" => 42,
  "skipped_count" => 0,
  "failed_count" => 3,
  "errors" => [
    { "item_id" => 123, "title" => "Album Name", "error" => "MusicBrainz API timeout" }
  ],
  "imported_at" => "2025-01-23T15:30:00Z"
}
```

## Item Selection Criteria

Items are eligible for import when ALL conditions are met:
- `listable_id` is nil (not already linked to an album)
- `metadata['mb_release_group_id']` is present
- `metadata['imported_at']` is nil (not previously imported)
- `metadata['ai_match_invalid']` is not "true"

## Idempotency

Job is designed to be safely retried:
- Items with `imported_at` already set are skipped
- Items already linked (`listable_id` present) are skipped
- Running again after completion processes zero items

## ListItem Metadata After Import

**On Success:**
```ruby
{
  "title" => "The Dark Side of the Moon",
  "artists" => ["Pink Floyd"],
  "mb_release_group_id" => "abc123...",
  "imported_at" => "2025-12-27T15:30:00Z",
  "imported_album_id" => 456
}
```

**On Failure:**
```ruby
{
  "title" => "Album Name",
  "mb_release_group_id" => "abc123...",
  "import_error" => "MusicBrainz API timeout",
  "import_attempted_at" => "2025-12-27T15:30:00Z"
}
```

## Error Handling

- **Empty list**: Updates wizard_state to completed with zero counts
- **Individual item failures**: Logged, counted as failed, processing continues
- **Critical failures**: Updates wizard_state to failed, re-raises for Sidekiq retry
- **List not found**: Raises `ActiveRecord::RecordNotFound` for Sidekiq retry

## Queue

Uses default Sidekiq queue (no custom queue specified).

## Dependencies

- `DataImporters::Music::Album::Importer` - Album import from MusicBrainz
- `Music::Albums::List` - List model with wizard_manager helpers
- `Services::Lists::Wizard::Music::Albums::StateManager` - Wizard state management

## Related Files

- `app/lib/data_importers/music/album/importer.rb` - Album importer service
- `app/lib/data_importers/music/album/providers/music_brainz.rb` - MusicBrainz provider
- `app/controllers/admin/music/albums/list_wizard_controller.rb` - Enqueues this job
- `app/components/admin/music/albums/wizard/import_step_component.rb` - UI component
- `test/sidekiq/music/albums/wizard_import_albums_job_test.rb` - 18 tests

## Usage

```ruby
# Enqueue job
Music::Albums::WizardImportAlbumsJob.perform_async(list.id)

# Check progress via wizard_manager
list.reload
manager = list.wizard_manager
manager.step_status("import")    # => "running" | "completed" | "failed"
manager.step_progress("import")  # => 0-100
manager.step_metadata("import")  # => { "imported_count" => 42, ... }
manager.step_error("import")     # => nil or error message
```

## Performance

- MusicBrainz API calls: ~200-500ms per item (rate limited)
- Progress updates: ~10ms overhead per batch
- Expected completion: < 10 minutes for 100 items (MusicBrainz rate limiting is main constraint)
