# Music::Artist::Merger

## Summary
Service class that merges two artists by transferring all associations from a source artist to a target artist, then destroying the source. Used for deduplication when the same artist exists under multiple records.

## Location
`app/lib/music/artist/merger.rb`

## Public Methods

### `.call(source:, target:)`
Class method entry point for merging artists.
- Parameters:
  - `source` (Music::Artist) - The artist to merge from (will be deleted)
  - `target` (Music::Artist) - The artist to merge into (will be preserved)
- Returns: `Result` struct with `success?`, `data`, and `errors` attributes

### `#call`
Instance method that performs the merge operation.
- Returns: `Result` struct
- Side effects:
  - Transfers all associations from source to target
  - Destroys source artist
  - Creates search index request for target
  - Schedules ranking recalculation jobs

## Result Struct
```ruby
Result = Struct.new(:success?, :data, :errors, keyword_init: true)
```
- `success?` (Boolean) - Whether the merge completed successfully
- `data` (Music::Artist|nil) - The target artist on success, nil on failure
- `errors` (Array<String>) - Error messages if merge failed

## Associations Merged

| Association | Method | Duplicate Handling |
|-------------|--------|-------------------|
| `album_artists` | `merge_album_artists` | Skip if album already linked to target |
| `song_artists` | `merge_song_artists` | Skip if song already linked to target |
| `band_memberships` | `merge_band_memberships` | Skip if same member exists on target |
| `memberships` | `merge_memberships` | Skip if same band exists on target |
| `credits` | `merge_credits` | Transfer all (bulk update) |
| `identifiers` | `merge_identifiers` | Skip if same type+value exists |
| `category_items` | `merge_category_items` | Use find_or_create_by |
| `images` | `merge_images` | Transfer, preserve target's primary |
| `external_links` | `merge_external_links` | Transfer all (bulk update) |

## Behavior

### Preconditions
- Source and target must be different artists (same ID returns error)

### Transaction Safety
All association transfers and the source deletion happen within a single database transaction. If any step fails, all changes are rolled back.

### Post-Merge Actions
1. Target artist is `touch`ed to update timestamps
2. `SearchIndexRequest` created to reindex target artist
3. `BulkCalculateWeightsJob` scheduled for affected ranking configurations
4. `CalculateRankingsJob` scheduled 5 minutes later for affected configurations

## Error Handling
- `ActiveRecord::RecordInvalid` - Validation failures
- `ActiveRecord::RecordNotUnique` - Constraint violations
- General exceptions - Caught and returned as error result

## Usage Example
```ruby
source = Music::Artist.find(123)  # Duplicate "Beatles"
target = Music::Artist.find(456)  # Canonical "The Beatles"

result = Music::Artist::Merger.call(source: source, target: target)

if result.success?
  puts "Merged into #{result.data.name}"
else
  puts "Errors: #{result.errors.join(', ')}"
end
```

## Stats
The merger tracks counts of merged associations in the `@stats` hash, accessible via `merger.stats` after calling. Keys include:
- `:album_artists`, `:song_artists`, `:band_memberships`, `:memberships`
- `:credits`, `:identifiers`, `:category_items`, `:images`, `:external_links`

## Related Classes
- `Music::Song::Merger` - Similar pattern for song merging
- `Music::Album::Merger` - Similar pattern for album merging
- `Actions::Admin::Music::MergeArtist` - Admin action that invokes this merger

## Dependencies
- `SearchIndexRequest` - For queuing search reindexing
- `BulkCalculateWeightsJob` - For recalculating ranking weights
- `CalculateRankingsJob` - For recalculating final rankings
