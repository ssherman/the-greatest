# Services::Lists::Music::Albums::ItemsJsonImporter

## Summary
Service that imports albums from MusicBrainz and creates list_items for Music::Albums::List records based on enriched and validated items_json data. This is Phase 3 of the three-phase list import workflow.

## Purpose
Completes the list import workflow by converting enriched and validated items_json entries into actual database records. Loads existing albums directly when possible, imports missing albums from MusicBrainz, creates verified list_items with proper positioning, and prevents duplicates.

## Public Methods

### `.call(list:)`
Class method that creates and executes the importer service
- Parameters:
  - `list` (Music::Albums::List) - The list containing enriched items_json data
- Returns: `ItemsJsonImporter::Result` struct

### `#call`
Executes the import process
- Returns: `ItemsJsonImporter::Result` with:
  - `success`: Boolean indicating overall success
  - `message`: Human-readable summary
  - `imported_count`: Number of albums imported from MusicBrainz
  - `created_directly_count`: Number of list_items created from existing albums (no import)
  - `skipped_count`: Number of albums skipped (invalid, not enriched, or duplicates)
  - `error_count`: Number of errors encountered
  - `data`: Hash containing detailed statistics and error messages

## Result Structure

### ItemsJsonImporter::Result
Struct with the following fields:
- `success` (Boolean) - Overall success status
- `data` (Hash) - Detailed statistics:
  - `total_albums`: Total number of albums processed
  - `imported`: Albums imported from MusicBrainz
  - `created_directly`: List items created from existing albums
  - `skipped`: Albums intentionally skipped
  - `errors`: Number of errors
  - `error_messages`: Array of error message strings
- `message` (String) - Summary message
- `imported_count` (Integer)
- `created_directly_count` (Integer)
- `skipped_count` (Integer)
- `error_count` (Integer)

## Processing Logic

### Import Flow
1. Validate list has valid items_json structure
2. Iterate through albums array
3. For each album:
   - Skip if `ai_match_invalid: true` (failed AI validation)
   - Skip if missing both `album_id` and `mb_release_group_id` (not enriched)
   - Try loading existing album by `album_id` (fast path)
   - Fall back to importing by `mb_release_group_id` if needed (slow path)
   - Check for existing list_item to prevent duplicates
   - Create new list_item with `verified: true` if album found

### Performance Optimization
**Fast Path**: When `album_id` is present (album already exists in database):
- Loads album directly via `Music::Album.find_by(id:)`
- No MusicBrainz API call needed
- Tracks as `created_directly_count`

**Slow Path**: When only `mb_release_group_id` present (album needs importing):
- Calls `DataImporters::Music::Album::Importer.call(release_group_musicbrainz_id:)`
- Makes MusicBrainz API call
- Runs full provider chain
- Tracks as `imported_count`

**Fallback**: If `album_id` exists but album not found in database:
- Logs warning
- Falls back to import via `mb_release_group_id` if available
- Ensures robustness against deleted albums

### Skip Conditions
Albums are skipped when:
- `ai_match_invalid: true` - AI flagged as incorrect match
- Missing both `album_id` and `mb_release_group_id` - Not enriched
- List item already exists for album - Duplicate prevention

### Error Handling
- Album import failures are logged but don't stop processing
- Exceptions during individual album processing are caught and logged
- Service returns success with error counts for partial completion
- Overall exceptions (validation failures) are re-raised

## Validations

### Input Validation
- `list` must be present
- `list.items_json` must be present
- `items_json["albums"]` must be an Array
- `items_json["albums"]` must not be empty

### Duplicate Prevention
Uses `list.list_items.exists?(listable: album)` check before creating list_items to ensure idempotent re-runs.

## Dependencies
- `Music::Albums::List` - ActiveRecord model
- `Music::Album` - ActiveRecord model with `with_musicbrainz_release_group_id` scope
- `DataImporters::Music::Album::Importer` - Album import service
- `ListItem` - Polymorphic list item model

## Usage Example

```ruby
# Import albums from enriched items_json
list = Music::Albums::List.find(123)
result = Services::Lists::Music::Albums::ItemsJsonImporter.call(list: list)

if result.success
  puts result.message
  # => "Imported 15 albums, created 45 from existing albums, skipped 3, 0 errors"

  puts "Total: #{result.data[:total_albums]}"
  puts "New imports: #{result.imported_count}"
  puts "Existing albums: #{result.created_directly_count}"
  puts "Skipped: #{result.skipped_count}"
else
  puts "Import failed: #{result.message}"
  puts result.data[:error_messages]
end
```

## Performance Considerations

### Efficiency Optimizations
- **Direct loading preferred**: Checks `album_id` first to avoid unnecessary MusicBrainz API calls
- **Separate count tracking**: Distinguishes imported (slow) vs directly loaded (fast) for visibility
- **Idempotent design**: Can be safely re-run without creating duplicates
- **Graceful partial failure**: One failed album doesn't stop processing others

### Expected Performance
For a 100-album list where 80 already exist in database:
- Makes only 20 MusicBrainz API calls (vs 100 without optimization)
- Creates 100 list_items (single INSERT each)
- Processes in background via Sidekiq job

## Related Classes
- `Services::Lists::Music::Albums::ItemsJsonEnricher` - Phase 1: Adds MusicBrainz metadata
- `Services::Ai::Tasks::Lists::Music::Albums::ItemsJsonValidatorTask` - Phase 2: AI validation
- `Music::Albums::ImportListItemsFromJsonJob` - Sidekiq job that invokes this service
- `Avo::Actions::Lists::Music::Albums::ImportItemsFromJson` - Admin action to trigger import
- `DataImporters::Music::Album::Importer` - Used for importing missing albums

## Implementation Notes

### Three-Phase Workflow
This service completes the three-phase list import workflow:
1. **Enrichment**: ItemsJsonEnricher adds MusicBrainz IDs and album_ids
2. **Validation**: ItemsJsonValidatorTask flags invalid matches
3. **Import** (this service): Creates verified list_items from validated data

### Verified List Items
All created list_items are marked as `verified: true` because:
- Data has been through MusicBrainz enrichment
- Data has been through AI validation
- Albums successfully imported/loaded from database
- Higher quality than manual list creation

### Position Field
The `rank` field from items_json (1, 2, 3...) is used as the `position` field on list_items, preserving the original list ordering.
