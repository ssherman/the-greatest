# Services::Lists::Music::Songs::ItemsJsonImporter

## Summary
Imports songs from a list's `items_json` JSONB field into list_items. This service handles the complete workflow of processing enriched JSON data, validating songs, loading or importing them into the database, and creating corresponding list_items. Part of the Music::Songs domain.

## Overview
This service implements a three-phase workflow for importing songs from structured JSON data:

1. **Enrichment Phase** (prerequisite): The `items_json` field must be pre-populated with song data that has been enriched with either `song_id` (existing songs in database) or `mb_recording_id` (MusicBrainz recording identifiers).

2. **Validation Phase**: The service validates that songs are properly enriched and not flagged as invalid by AI matching.

3. **Import Phase**: Songs are either loaded from the database or imported from MusicBrainz, then list_items are created with proper rankings.

### Design Decision: Load vs Import
The service distinguishes between two types of song processing:
- **Loading**: When `song_id` is present, the song already exists in the database and is simply loaded
- **Importing**: When `mb_recording_id` is present (and no `song_id`), the song must be imported from MusicBrainz using `DataImporters::Music::Song::Importer`

This separation allows for efficient processing of lists that mix existing songs with new songs that need to be imported.

## Public Methods

### `.call(list:)`
Class-level convenience method that instantiates and calls the service.
- **Parameters**:
  - `list` (Music::Songs::List) - The list containing `items_json` to import
- **Returns**: `Result` struct with import statistics and status
- **Example**:
  ```ruby
  result = Services::Lists::Music::Songs::ItemsJsonImporter.call(list: my_list)
  if result.success
    puts "Imported: #{result.imported_count}, Created: #{result.created_directly_count}"
  end
  ```

### `#call`
Executes the import process, iterating through all songs in `items_json` and processing each one.
- **Returns**: `Result` struct containing:
  - `success` (Boolean) - Whether the overall import succeeded
  - `message` (String) - Summary message of import results
  - `imported_count` (Integer) - Number of songs imported from MusicBrainz
  - `created_directly_count` (Integer) - Number of list_items created from existing songs
  - `skipped_count` (Integer) - Number of songs skipped (invalid or not enriched)
  - `error_count` (Integer) - Number of songs that failed to process
  - `data` (Hash) - Detailed breakdown including error messages
- **Side Effects**:
  - Creates new `Music::Song` records via MusicBrainz import
  - Creates new `ListItem` records linking songs to the list
  - Logs progress and errors to Rails logger
- **Raises**: `ArgumentError` if list validation fails

## Result Struct

### Structure
```ruby
Result = Struct.new(
  :success,              # Boolean
  :data,                 # Hash
  :message,              # String
  :imported_count,       # Integer - songs imported from MusicBrainz
  :created_directly_count, # Integer - list_items for existing songs
  :skipped_count,        # Integer - songs skipped
  :error_count,          # Integer - songs that errored
  keyword_init: true
)
```

### Data Hash Contents
```ruby
{
  total_songs: 100,
  imported: 25,              # New songs imported from MusicBrainz
  created_directly: 60,      # List items for existing songs
  skipped: 10,               # Invalid or not enriched
  errors: 5,
  error_messages: [...]      # Array of error strings
}
```

## Expected items_json Structure

The `items_json` field should contain a hash with a `songs` array:

```json
{
  "songs": [
    {
      "rank": 1,
      "title": "Bohemian Rhapsody",
      "song_id": 12345,                    // Existing song in database (optional)
      "song_name": "Bohemian Rhapsody",
      "mb_recording_id": "b1a9c0e9-d58a-4182-9e7c-ffd1f85dae2e",  // MusicBrainz ID (optional)
      "ai_match_invalid": false            // AI validation flag (optional)
    }
  ]
}
```

### Required Fields per Song
- `rank` - Position in the list (used for `position` attribute)
- At least one of:
  - `song_id` - ID of existing song in database
  - `mb_recording_id` - MusicBrainz recording identifier

### Optional Fields per Song
- `ai_match_invalid` - If `true`, song is skipped (AI flagged as poor match)
- `title` - Song title (for logging purposes)
- `song_name` - Song name (for logging purposes)

## Processing Logic

### Skip Conditions
Songs are skipped and counted in `skipped_count` if:
1. `ai_match_invalid` is `true` - AI flagged the match as invalid
2. Neither `song_id` nor `mb_recording_id` is present - Song not enriched

### Song Loading/Importing Priority
1. **First**: Try to load by `song_id` if present
   - If found: Increment `created_directly_count` (if list item will be created)
   - If not found: Fall through to MusicBrainz import (if available)
2. **Second**: Try to import by `mb_recording_id` if present
   - Uses `DataImporters::Music::Song::Importer`
   - If successful: Increment `imported_count` (if list item will be created)
   - If failed: Increment `error_count`
3. **Neither**: Increment `error_count`

### List Item Creation
After successfully loading or importing a song:
- Check if list item already exists for this song
- If exists: Skip and increment `skipped_count`
- If not exists: Create with `position: rank` and `verified: true`

### Error Handling
- Individual song errors are caught, logged, and counted but don't stop processing
- Validation errors (invalid list, missing items_json) raise `ArgumentError`
- All errors are collected in the result's `error_messages` array

## Validations

The service validates:
1. List is present
2. List has `items_json` attribute populated
3. `items_json` contains a `songs` array
4. `songs` array is not empty

## Dependencies

### Direct Dependencies
- `Music::Songs::List` - The list model containing `items_json`
- `Music::Song` - Song model for database lookups
- `ListItem` - Polymorphic join model connecting songs to lists
- `DataImporters::Music::Song::Importer` - Service for importing songs from MusicBrainz

### Indirect Dependencies
- MusicBrainz API (via `DataImporters::Music::Song::Importer`)
- External providers for song data enrichment

## Usage Examples

### Basic Import
```ruby
# Assuming list.items_json is already enriched
list = Music::Songs::List.find(123)
result = Services::Lists::Music::Songs::ItemsJsonImporter.call(list: list)

puts result.message
# => "Imported 25 songs, created 60 from existing songs, skipped 10, 5 errors"
```

### Error Handling
```ruby
result = Services::Lists::Music::Songs::ItemsJsonImporter.call(list: list)

if result.success
  Rails.logger.info "Successfully processed #{result.data[:total_songs]} songs"
else
  Rails.logger.error "Import failed: #{result.message}"
  result.data[:error_messages].each do |error|
    Rails.logger.error "  - #{error}"
  end
end
```

### Checking Import Statistics
```ruby
result = Services::Lists::Music::Songs::ItemsJsonImporter.call(list: list)

puts "Total songs: #{result.data[:total_songs]}"
puts "Newly imported from MusicBrainz: #{result.imported_count}"
puts "Created from existing database songs: #{result.created_directly_count}"
puts "Skipped (invalid or not enriched): #{result.skipped_count}"
puts "Errors: #{result.error_count}"
```

## Background Job Integration

This service is designed to be called from `Music::Songs::ImportListItemsFromJsonJob` for asynchronous processing:

```ruby
# Enqueue the job
Music::Songs::ImportListItemsFromJsonJob.perform_async(list.id)

# Job calls the service
result = Services::Lists::Music::Songs::ItemsJsonImporter.call(list: list)
```

## Testing Approach

### Unit Testing
Test the service with various `items_json` configurations:

1. **Happy Path Tests**:
   - Mix of existing songs (`song_id`) and new imports (`mb_recording_id`)
   - Verify correct counts for imported vs created directly
   - Verify list_items created with correct positions

2. **Skip Condition Tests**:
   - Songs with `ai_match_invalid: true`
   - Songs without `song_id` or `mb_recording_id`
   - Songs already in the list (duplicate prevention)

3. **Error Handling Tests**:
   - Invalid MusicBrainz IDs
   - Non-existent `song_id` values
   - Missing or malformed `items_json`

4. **Validation Tests**:
   - Nil list
   - List without `items_json`
   - Empty `songs` array

### Integration Testing
- Test with actual MusicBrainz API responses (use VCR)
- Verify interaction with `DataImporters::Music::Song::Importer`
- Test complete workflow from JSON to list_items

### Test Fixtures
Create fixtures with:
- Valid enriched songs (both `song_id` and `mb_recording_id`)
- Songs flagged as invalid
- Duplicate songs
- Mixed scenarios

## Performance Considerations

### N+1 Query Prevention
- Service uses `find_by` for single lookups
- Duplicate checking uses `exists?` for efficiency
- Consider preloading existing list_items if processing very large lists

### Large List Optimization
For lists with hundreds of songs:
- Service processes sequentially (trade-off for reliability)
- Consider batching if memory becomes an issue
- Background job prevents timeout issues

### Database Transaction Strategy
- No explicit transaction wrapper (processes one at a time)
- Individual song failures don't roll back successful imports
- This design choice favors partial success over all-or-nothing

## Related Documentation
- [Music::Songs::List](/home/shane/dev/the-greatest/docs/models/music/songs/list.md)
- [ListItem](/home/shane/dev/the-greatest/docs/models/list_item.md)
- [Music::Song](/home/shane/dev/the-greatest/docs/models/music/song.md)
- [DataImporters::Music::Song::Importer](/home/shane/dev/the-greatest/docs/models/data_importers/music/song/importer.md)
- [Music::Songs::ImportListItemsFromJsonJob](/home/shane/dev/the-greatest/docs/models/sidekiq/music/songs/import_list_items_from_json_job.md)

## See Also
- Avo action: `Avo::Actions::Lists::Music::Songs::ImportItemsFromJson` - Admin UI trigger for this service
- Spec documentation: [`docs/specs/066-import-songs-from-items-json.md`](/home/shane/dev/the-greatest/docs/specs/066-import-songs-from-items-json.md)
