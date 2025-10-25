# ItemRankings::Music::Artists::Calculator

## Summary
Service class that calculates artist rankings by aggregating scores from both album and song rankings. Extends the base `ItemRankings::Calculator` class but uses a unique aggregation approach instead of the standard list-based weighted ranking.

This is the core service that powers "The Greatest Artists" rankings on The Greatest Music.

## Purpose
Unlike albums and songs which aggregate from external lists (e.g., "Rolling Stone's 500 Greatest Albums"), artist rankings are calculated by:
1. Summing all album scores for each artist from the primary album ranking configuration
2. Summing all song scores for each artist from the primary song ranking configuration
3. Combining both scores to create a total artist score
4. Ranking artists by total score (highest to lowest)

This approach rewards artists who excel in both albums and individual songs.

## Public Methods

### `#call`
Main entry point for calculating artist rankings. Invoked by `RankingConfiguration#calculate_rankings`.

**Returns:** `Result` struct with:
- `success?` (Boolean) - Whether calculation succeeded
- `data` (Array) - Array of hashes with `:id` and `:score` for each artist
- `errors` (Array) - Error messages if calculation failed

**Side Effects:**
- Creates/updates `RankedItem` records for all artists in the ranking
- Removes `RankedItem` records for artists no longer in ranking (e.g., zero scores)
- All changes happen within a database transaction

**Example:**
```ruby
config = Music::Artists::RankingConfiguration.default_primary
calculator = ItemRankings::Music::Artists::Calculator.new(config)
result = calculator.call

if result.success?
  puts "Calculated rankings for #{result.data.count} artists"
  result.data.first # => { id: 123, score: 1250.75 }
else
  puts "Errors: #{result.errors.join(', ')}"
end
```

## Protected Methods

### `#list_type`
Raises `NotImplementedError` since artists don't use list-based ranking.

**Raises:** `NotImplementedError` with message "Artists use aggregation from album/song rankings, not list-based ranking"

### `#item_type`
Returns the item type string for polymorphic associations.

**Returns:** `"Music::Artist"`

## Private Methods

### `#calculate_all_artist_scores`
Calculates scores for all artists in the system by aggregating from album and song rankings.

**Algorithm:**
1. Fetch the default primary album ranking configuration
2. Fetch the default primary song ranking configuration
3. Return empty array if either configuration is missing
4. Iterate through all artists using `find_each` (for memory efficiency)
5. For each artist, calculate score from both albums and songs
6. Skip artists with zero scores
7. Sort artists by score (descending)

**Returns:** Array of hashes: `[{ id: 123, score: 1250.75 }, { id: 456, score: 980.50 }, ...]`

**Performance:** Uses `includes(:albums, :songs)` to avoid N+1 queries when accessing artist associations.

### `#calculate_artist_score(artist, album_config, song_config)`
Calculates the total score for a single artist by summing their album and song scores.

**Parameters:**
- `artist` (Music::Artist) - The artist to calculate score for
- `album_config` (Music::Albums::RankingConfiguration) - Album ranking configuration to use
- `song_config` (Music::Songs::RankingConfiguration) - Song ranking configuration to use

**Returns:** Decimal - Total score (sum of album scores + song scores)

**Algorithm:**
```ruby
album_scores = RankedItem
  .where(item_type: "Music::Album", item_id: artist.albums.pluck(:id))
  .where(ranking_configuration_id: album_config.id)
  .sum(:score)

song_scores = RankedItem
  .where(item_type: "Music::Song", item_id: artist.songs.pluck(:id))
  .where(ranking_configuration_id: song_config.id)
  .sum(:score)

album_scores + song_scores
```

**Performance Notes:**
- Uses `pluck(:id)` to get IDs efficiently
- Uses `sum(:score)` which is executed in the database (not in Ruby)
- Single query for albums, single query for songs

### `#update_ranked_items_from_scores(artists_with_scores)`
Updates the `ranked_items` table with the calculated artist rankings.

**Parameters:**
- `artists_with_scores` (Array) - Array of hashes with `:id` and `:score` for each artist

**Side Effects:**
1. Creates `RankedItem` records for all artists in the ranking
2. Updates existing `RankedItem` records if artist was already ranked
3. Removes `RankedItem` records for artists no longer in the ranking
4. All operations happen within a database transaction

**Algorithm:**
1. Build array of ranked_items_data with rank assignments (1, 2, 3, etc.)
2. Skip artists with zero scores
3. Use `upsert_all` to efficiently create/update records in bulk
4. Delete ranked_items for artists not in current ranking

**Performance:**
- Uses `upsert_all` for bulk insert/update (single query)
- Uses `delete_all` for bulk deletion (single query)
- All wrapped in transaction for atomicity

## Dependencies

### Models
- `Music::Artist` - The artists being ranked
- `Music::Albums::RankingConfiguration` - Source of album scores
- `Music::Songs::RankingConfiguration` - Source of song scores
- `RankedItem` - Stores the calculated artist rankings

### Services
- Extends `ItemRankings::Calculator` base class
- Uses `Result` struct from base calculator

### Database Tables
- `music_artists` - Artist data
- `ranking_configurations` - Configuration data
- `ranked_items` - Ranking results

## Key Design Decisions

### Why Aggregate from Album + Song Rankings?
**Decision:** Calculate artist scores by summing their album and song scores.

**Rationale:**
- No canonical "greatest artists" lists exist like they do for albums/songs
- Artist quality is best measured by the quality of their output (albums + songs)
- Automatic updates when album/song rankings change
- Rewards both album-oriented artists (e.g., Pink Floyd) and singles-oriented artists (e.g., Madonna)
- Objective, data-driven approach

### Why Sum Instead of Average?
**Decision:** Total artist score = sum of album scores + sum of song scores (not average).

**Rationale:**
- Rewards prolific artists with large catalogs of acclaimed work
- Intuitive: more great work = higher rank
- Fair to different artist types (album artists vs singles artists)
- Matches user expectations (Beatles should rank higher than one-hit wonders)

### Why Recalculate All Artists (Not Incremental)?
**Decision:** Always recalculate all artists, even when triggered by single artist.

**Rationale:**
- Rankings are relative (rank depends on all other artists' scores)
- One artist's score changing could shift many ranks
- Ensures consistency across all artist rankings
- Simplifies implementation (one code path)
- Performance acceptable (< 5 minutes for 10k artists)

### Why Exclude Zero Scores?
**Decision:** Artists with zero total score are excluded from rankings.

**Rationale:**
- Zero score means artist has no ranked albums or songs
- Including them would create misleading ranks (e.g., "Ranked #5000")
- Cleaner user experience to only show artists with measured acclaim
- Avoids ranking artists with insufficient data

## Performance Characteristics

**Expected Performance:**
- ~100 artists: < 1 second
- ~1,000 artists: ~5 seconds
- ~10,000 artists: < 5 minutes

**Optimization Techniques:**
- `find_each` for memory-efficient iteration
- `includes` for eager loading associations
- `pluck` for efficient ID fetching
- `sum(:score)` in database (not Ruby)
- `upsert_all` for bulk inserts/updates
- Transaction wrapping for atomicity

**Potential Bottlenecks:**
- Artists with 50+ albums (many IDs in `WHERE IN` clause)
- Database server load during calculation
- Lock contention on `ranked_items` table

## Error Handling

**Missing Configurations:**
Returns empty array if album or song ranking configurations are missing. This prevents errors but results in zero artists being ranked.

**Database Errors:**
All errors are caught and returned in the `Result` struct:
```ruby
rescue => error
  Result.new(success?: false, data: nil, errors: [error.message])
end
```

**Transaction Rollback:**
If `update_ranked_items_from_scores` fails, the transaction rolls back and no `RankedItem` records are modified.

## Usage Example

```ruby
# Typically invoked via RankingConfiguration
config = Music::Artists::RankingConfiguration.default_primary
result = config.calculate_rankings

# Can also be invoked directly
calculator = ItemRankings::Music::Artists::Calculator.new(config)
result = calculator.call

# Check result
if result.success?
  puts "Ranked #{result.data.count} artists"

  # Access the rankings
  config.ranked_items.order(:rank).limit(10).each do |ranked_item|
    artist = ranked_item.item
    puts "##{ranked_item.rank}: #{artist.name} (#{ranked_item.score})"
  end
else
  puts "Calculation failed: #{result.errors.join(', ')}"
end
```

## Related Documentation
- [Music::Artists::RankingConfiguration](/home/shane/dev/the-greatest/docs/models/music/artists/ranking_configuration.md)
- [ItemRankings::Calculator](/home/shane/dev/the-greatest/docs/lib/item_rankings/calculator.md) (base class)
- [Music::CalculateAllArtistsRankingsJob](/home/shane/dev/the-greatest/docs/sidekiq/music/calculate_all_artists_rankings_job.md)
- [Music::Artist](/home/shane/dev/the-greatest/docs/models/music/artist.md)
