# Music::Song::Merger

## Summary
Service object for merging two Music::Song records, consolidating all associated data from a source song into a target song, then deleting the source. This is an admin-only operation used to clean up duplicate song entries.

## Purpose
When importing music data from various sources (MusicBrainz, user submissions, AI parsing), duplicate song entries can be created. This service safely merges all associations from one song into another, maintaining data integrity through database transactions.

## Usage

```ruby
source_song = Music::Song.find(123)  # The duplicate to be deleted
target_song = Music::Song.find(456)  # The canonical song to keep

result = Music::Song::Merger.call(source: source_song, target: target_song)

if result.success?
  puts "Merged successfully!"
  puts "Merged data: #{result.data.inspect}"
else
  puts "Merge failed: #{result.errors.join(', ')}"
end
```

## Return Value

Returns a `Result` struct with:
- `success?` (Boolean) - Whether the merge succeeded
- `data` (Music::Song) - The target song if successful, nil otherwise
- `errors` (Array<String>) - Error messages if merge failed

## Associations Merged

### Direct Reassignments (Single SQL Query)
- **tracks** - All Music::Track records pointing to source reassigned to target
- **identifiers** - All external system IDs (MusicBrainz recording IDs, ISRCs, etc.) moved to target
- **external_links** - Purchase links, reviews, information links moved to target

### Find-or-Create (Handles Unique Constraints)
- **category_items** - Genre/style categorizations merged, duplicates skipped
- **list_items** - Appearances in user/editorial lists merged, position preserved when possible
- **song_relationships** (forward) - Songs this song relates to (covers, remixes, samples, alternates)
- **inverse_song_relationships** (reverse) - Other songs that relate to this song

### Not Merged (Intentionally)
- **song_artists** - Target's artists preserved; source's destroyed automatically via `dependent: :destroy`
- **credits** - Not currently populated; deferred until credits are in use
- **ai_chats** - Historical AI conversations not valuable to preserve; destroyed automatically
- **ranked_items** - Source's rankings destroyed; target's preserved; triggers recalculation jobs

## Self-Reference Handling

The merger intelligently prevents invalid self-references:

**Forward Relationships**: If source song covers target song, this relationship is skipped (would create "target covers target").

**Inverse Relationships**: If another song relates to both source and target in the same way, the duplicate is destroyed.

```ruby
# Example:
# Before merge:
#   Song A (source) -> covers -> Song C
#   Song B (target) -> covers -> Song C  (already exists)
# After merge:
#   Song B -> covers -> Song C  (no duplicate created)
```

## Transaction Safety

All operations wrapped in a single database transaction:
- If ANY step fails, ALL changes are rolled back
- Source song remains unchanged on failure
- No partial merges possible
- Safe to retry after fixing errors

## Search Indexing

Search index updates happen automatically via the `SearchIndexable` concern:
- Target song: Reindexed via `touch` (triggers `after_commit` callback)
- Source song: Unindexed on `destroy` (triggers `after_commit` callback)

No manual `SearchIndexRequest` creation needed.

## Ranking Recalculation

If either song has `ranked_items` in any `RankingConfiguration`:
1. Collects all affected configuration IDs before merge
2. After transaction commits successfully:
   - Schedules `BulkCalculateWeightsJob` immediately
   - Schedules `CalculateRankingsJob` 5 minutes later (allows weights to complete)

## Error Handling

Returns structured error results for:
- `ActiveRecord::RecordInvalid` - Validation failures
- `ActiveRecord::RecordNotUnique` - Unique constraint violations
- Any other exception - Generic error with message

Transaction automatically rolls back on any error.

## Public Methods

### `.call(source:, target:)`
Class method for executing the merge.

**Parameters**:
- `source` (Music::Song) - The song to be merged and deleted
- `target` (Music::Song) - The song to receive all merged data

**Returns**: Result struct with `success?`, `data`, and `errors`

### `#initialize(source:, target:)`
Constructor.

**Parameters**:
- `source` (Music::Song) - The source song
- `target` (Music::Song) - The target song

**Attributes**:
- `source_song` (Music::Song) - Readable source song reference
- `target_song` (Music::Song) - Readable target song reference
- `stats` (Hash) - Readable hash of merge statistics (counts per association)

## Performance

- Simple reassignments use `update_all` (single SQL query per association type)
- Complex merges use `find_each` for batch processing (avoids memory issues)
- Find-or-create pattern prevents N+1 queries via proper scoping
- Typical merge completes in under 1 second
- Transaction overhead minimal for inline processing

## Example Stats Output

```ruby
{
  tracks: 5,                      # 5 tracks reassigned
  identifiers: 3,                 # 3 external IDs moved
  category_items: 2,              # 2 categories merged
  external_links: 1,              # 1 link moved
  list_items: 4,                  # 4 list appearances merged
  song_relationships: 0,          # No forward relationships
  inverse_song_relationships: 2   # 2 other songs now point to target
}
```

## Dependencies

- `Music::Song` - Model being merged
- `Music::Track` - Track associations
- `Music::SongRelationship` - Song relationship model
- `Identifier` - External ID model
- `CategoryItem` - Genre/style associations
- `ExternalLink` - External link model
- `ListItem` - List association model
- `RankedItem` - Ranking results model
- `BulkCalculateWeightsJob` - Ranking weight calculation job
- `CalculateRankingsJob` - Ranking calculation job

## Related Classes

- `Music::Album::Merger` - Similar merge service for albums (reference implementation)
- `Categories::Merger` - Category merge service
- `Avo::Actions::Music::MergeSong` - Admin UI action that calls this service

## Testing

Comprehensive test coverage in `test/lib/music/song/merger_test.rb`:
- 23 tests covering all merge scenarios
- Self-reference edge cases
- Transaction rollback verification
- Association merge verification
- Ranking job scheduling
- Error handling

## Common Use Cases

1. **Duplicate from Import**: Same song imported via different routes (series import, album import, manual)
2. **Multiple MusicBrainz IDs**: Different recording IDs for same canonical song
3. **Metadata Correction**: Merge old incomplete record into new enriched one
4. **Release Consolidation**: Merge songs when better metadata becomes available

## Limitations

- Cannot merge songs by different artists (validation would fail on categorization)
- Cannot undo merge (permanent deletion of source)
- No preview of what will be merged
- No bulk merge support
- Credits merging deferred until credits are populated

## Future Enhancements

See `todos/067-song-merge-feature.md` Implementation Notes for planned improvements.
