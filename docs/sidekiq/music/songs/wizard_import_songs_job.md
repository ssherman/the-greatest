# Music::Songs::WizardImportSongsJob

## Summary
Background job that imports songs from MusicBrainz for a song list. Handles two import paths: Custom HTML (individual item imports) and MusicBrainz Series (bulk series import). Part of the song list wizard Step 5 (Import).

## Location
`app/sidekiq/music/songs/wizard_import_songs_job.rb`

## Interface

### `perform(list_id)`
Imports songs based on the `import_source` in the list's wizard_state.

**Parameters:**
- `list_id` (Integer) - ID of the `Music::Songs::List` to process

**Side Effects:**
- Updates `wizard_state` with step-namespaced progress and stats
- Updates `list_items.listable_id` when songs are imported
- Updates `list_items.verified` to true on successful import
- Updates `list_items.metadata` with import timestamps and errors

## Workflow

### Dispatch Logic
```ruby
import_source = list.wizard_state["import_source"]
if import_source == "musicbrainz_series"
  import_from_series
else
  import_from_custom_html
end
```

### Custom HTML Path
1. Find items needing import: `listable_id IS NULL AND metadata->>'mb_recording_id' IS NOT NULL AND metadata->>'imported_at' IS NULL`
2. Update wizard_step_status: `{status: "running", progress: 0}`
3. For each item:
   - Call `DataImporters::Music::Song::Importer.call(musicbrainz_recording_id:)`
   - On success: Set `listable_id`, `verified = true`, add `imported_at` to metadata
   - On failure: Add `import_error` and `import_attempted_at` to metadata
   - Update progress periodically
4. Update wizard_step_status: `{status: "completed", progress: 100}`

### MusicBrainz Series Path
1. Update wizard_step_status: `{status: "running", progress: 0}`
2. Call `DataImporters::Music::Lists::ImportSongsFromMusicbrainzSeries.call(list:)`
3. Mark all imported items as verified
4. Update wizard_step_status with results

## Progress Updates

Progress is updated to `wizard_state["steps"]["import"]`:
- Every 10 items processed (custom HTML path)
- Every 5 seconds (whichever comes first)
- Always at start (0%) and end (100%)

**Custom HTML Metadata:**
```ruby
{
  "import_source" => "custom_html",
  "processed_items" => 45,
  "total_items" => 100,
  "imported_count" => 40,
  "skipped_count" => 0,
  "failed_count" => 5,
  "errors" => [
    {"item_id" => 123, "title" => "Song", "error" => "Recording not found"}
  ],
  "imported_at" => "2025-01-23T15:30:00Z"
}
```

**Series Metadata:**
```ruby
{
  "import_source" => "musicbrainz_series",
  "imported_count" => 50,
  "total_count" => 52,
  "failed_count" => 2,
  "list_items_created" => 50,
  "verified_count" => 50,
  "imported_at" => "2025-01-23T15:30:00Z"
}
```

## Idempotency

Job is designed to be safely retried:
- Custom HTML: Only processes items where `listable_id IS NULL` AND `imported_at IS NULL`
- Items with `imported_at` set are skipped (even if `listable_id` is somehow nil)
- Series path: Re-running will only mark unverified items as verified

## Error Handling

- **Empty list (custom HTML)**: Completes immediately with zero counts
- **Individual item failures**: Logged, counted, stored in metadata, processing continues
- **Series failure**: Updates wizard_step_status to failed with error message
- **Critical failures**: Updates wizard_step_status to failed, re-raises exception
- **List not found**: Raises `ActiveRecord::RecordNotFound` for Sidekiq retry

## ListItem Metadata Updates

**On successful import:**
```ruby
item.metadata.merge(
  "imported_at" => Time.current.iso8601,
  "imported_song_id" => song.id
)
```

**On failed import:**
```ruby
item.metadata.merge(
  "import_error" => "Error message",
  "import_attempted_at" => Time.current.iso8601
)
```

## Queue

Uses default Sidekiq queue (no custom queue specified).

## Dependencies

- `DataImporters::Music::Song::Importer` - Individual song import (custom HTML path)
- `DataImporters::Music::Lists::ImportSongsFromMusicbrainzSeries` - Bulk series import
- `Music::Songs::List` - List model with wizard_step_status helpers

## Related Files

- `app/lib/data_importers/music/song/importer.rb` - Song importer
- `app/lib/data_importers/music/lists/import_songs_from_musicbrainz_series.rb` - Series importer
- `app/controllers/admin/music/songs/list_wizard_controller.rb` - Enqueues this job
- `app/components/admin/music/songs/wizard/import_step_component.rb` - UI component
- `test/sidekiq/music/songs/wizard_import_songs_job_test.rb` - 21 tests

## Usage

```ruby
# Enqueue job
Music::Songs::WizardImportSongsJob.perform_async(list.id)

# Check progress (step-namespaced)
list.reload
list.wizard_step_status("import")    # => "running" | "completed" | "failed"
list.wizard_step_progress("import")  # => 0-100
list.wizard_step_metadata("import")  # => { "imported_count" => 45, ... }
list.wizard_step_error("import")     # => nil or error message
```

## Performance

- Individual imports: ~200-500ms per item (MusicBrainz rate limiting)
- Series import: Depends on series size, handled by series importer service
- Progress updates: ~10ms overhead per batch
- Expected completion: < 2 minutes for 100 items (custom HTML path)
