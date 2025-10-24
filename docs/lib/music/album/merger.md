# Music::Album::Merger

## Summary
Service class that merges two Music::Album records by consolidating all associated data from a source album into a target album, then deleting the source album. Designed for combining duplicate album entries (e.g., duplicates from MusicBrainz imports).

**Location**: `web-app/app/lib/music/album/merger.rb`

## Purpose
Handles the complex process of merging duplicate album records while maintaining data integrity through database transactions. Used when the same album has been imported multiple times from external sources or created with duplicate entries.

## Public Methods

### `.call(source:, target:)`
Class method that creates a new merger instance and executes the merge operation.

**Parameters**:
- `source` (Music::Album) - The album to merge from (will be deleted)
- `target` (Music::Album) - The album to merge into (will be preserved)

**Returns**: `Result` struct with:
- `success?` (Boolean) - Whether the merge completed successfully
- `data` (Music::Album or nil) - The target album if successful, nil if failed
- `errors` (Array<String>) - Error messages if any failures occurred

**Example**:
```ruby
source_album = Music::Album.find(123)
target_album = Music::Album.find(456)

result = Music::Album::Merger.call(source: source_album, target: target_album)

if result.success?
  puts "Merged into: #{result.data.title}"
else
  puts "Errors: #{result.errors.join(', ')}"
end
```

## Associations Merged

The merger handles the following associations from source to target album:

### 1. Releases
- **Action**: Direct reassignment via `update_all`
- **Table**: `music_releases`
- All physical and digital releases transferred to target album
- Releases maintain their own associations (tracks, songs, credits, identifiers, images, external_links)

### 2. Identifiers
- **Action**: Direct reassignment via `update_all`
- **Table**: `identifiers` (polymorphic)
- External system IDs (MusicBrainz, Discogs, AllMusic, etc.) moved to target
- Critical for preventing future duplicates

### 3. Category Items
- **Action**: Find or create to handle duplicates
- **Table**: `category_items` (polymorphic)
- **Unique constraint**: `(category_id, item_type, item_id)`
- Genre and style categorizations merged without duplicates

### 4. Images
- **Action**: Direct reassignment with primary image conflict resolution
- **Table**: `images` (polymorphic)
- **Primary image handling**:
  - If target has primary image, all source images become non-primary
  - If target has no primary, source primary is preserved
- Ensures only one primary image per album

### 5. External Links
- **Action**: Direct reassignment via `update_all`
- **Table**: `external_links` (polymorphic)
- Purchase links, reviews, and information links transferred to target

### 6. List Items
- **Action**: Find or create to handle duplicates
- **Table**: `list_items` (polymorphic)
- **Unique constraint**: `(list_id, listable_type, listable_id)`
- Appearances in user and editorial lists merged without duplicates

## Associations NOT Merged

### Album Artists
- **Preserved**: Target album's artists remain unchanged
- **Rationale**: Merging is for duplicate album entries, not for combining different albums
- Source album artists are ignored to prevent data corruption

### Ranked Items
- **Destroyed**: Source album's ranked_items are deleted with the source album
- **Association**: `has_many :ranked_items, as: :item, dependent: :destroy`
- **Ranking recalculation**: Affected ranking configurations are identified and recalculated via background jobs

### AI Chats
- **Destroyed**: Historical AI conversations are not preserved
- **Rationale**: Not valuable to merge conversational history

## Transaction Safety

**Critical**: The entire merge operation is wrapped in a database transaction:

```ruby
ActiveRecord::Base.transaction do
  collect_affected_ranking_configurations
  merge_all_associations
  destroy_source_album
end
```

**Benefits**:
- **Atomicity**: All changes succeed or none do
- **Automatic rollback**: Any error (validation, constraint violation, DB error) rolls back everything
- **No partial merges**: Source and target albums remain unchanged on failure
- **Safe to retry**: Failed merge can be retried after fixing the issue

## Post-Merge Operations

After the transaction commits successfully, the following operations occur:

### 1. Search Index Update
- Target album queued for re-indexing via `SearchIndexRequest`
- Ensures search results reflect merged associations (categories, releases, etc.)
- Source album automatically unindexed when destroyed (via `SearchIndexable` concern)

### 2. Ranking Recalculation
For each affected `RankingConfiguration`:
- **Immediate**: `BulkCalculateWeightsJob.perform_async(config_id)` - Recalculates weights for ranked_lists
- **Delayed (5 min)**: `CalculateRankingsJob.perform_in(5.minutes, config_id)` - Recalculates ranks/scores for ranked_items
- **Sequencing**: Weights must be calculated before rankings, hence the delay

## Error Handling

The merger catches and handles three types of errors:

### ActiveRecord::RecordInvalid
- **Cause**: Validation failure during merge
- **Result**: Transaction rolled back, error message returned
- **Example**: Invalid album state

### ActiveRecord::RecordNotUnique
- **Cause**: Unexpected unique constraint violation
- **Result**: Transaction rolled back, constraint violation message returned
- **Example**: Database constraint not anticipated by find_or_create logic

### StandardError
- **Cause**: Any other unexpected error
- **Result**: Transaction rolled back, error message returned
- **Logging**: Error and backtrace logged to Rails logger

## Internal State

### Instance Variables
- `@source_album` - The album being merged from
- `@target_album` - The album being merged into
- `@stats` - Hash tracking counts of merged records (for logging/debugging)
- `@affected_ranking_configurations` - Array of ranking configuration IDs needing recalculation

## Usage in Admin Interface

Invoked via `Avo::Actions::Music::MergeAlbum` Avo action:
- Admin views target album (the "good" one)
- Selects "Merge Another Album Into This One" action
- Enters source album ID and confirms
- Action calls `Music::Album::Merger.call(source:, target:)`

## Dependencies

### Models
- `Music::Album` - Source and target models
- `Music::Release` - Released versions of the album
- `Identifier` - External system identifiers
- `CategoryItem` - Genre/style categorizations
- `Image` - Cover art and album images
- `ExternalLink` - Purchase/review/info links
- `ListItem` - List appearances
- `RankedItem` - Ranking system entries
- `SearchIndexRequest` - Search index queue

### Background Jobs
- `BulkCalculateWeightsJob` - Recalculates ranking weights
- `CalculateRankingsJob` - Recalculates ranking scores

### Concerns
- `SearchIndexable` - Automatically handles search index cleanup on album destruction

## Design Decisions

### Why Service Object Pattern?
- Complex multi-model operation
- Reusable logic outside Avo context
- Easier to test in isolation
- Clear Result object for success/failure handling

### Why No Artist Merging?
- Use case is duplicate album entries (same album imported twice)
- Not for combining different albums or fixing artist associations
- Prevents accidental multi-artist albums from single-artist duplicates
- Artist correction should be done directly on the album

### Why Destroy Ranked Items?
- Source and target albums may both be ranked in same configuration
- Unique constraint `(item_id, item_type, ranking_configuration_id)` prevents duplicates
- Target album's ranking preserved (more likely to be correct)
- Rankings recalculated to reflect merged data

### Why Transaction is Critical?
- Prevents partial merges that corrupt data
- Automatic rollback on any error
- Safe to retry failed merges
- No manual cleanup needed

## Related Documentation
- [Music::Album Model](../../models/music/album.md)
- [SearchIndexable Concern](../../concerns/search_indexable.md)
- [SearchIndexRequest Model](../../models/search_index_request.md)
