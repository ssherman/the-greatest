# Music::CalculateAllArtistsRankingsJob

## Summary
Sidekiq background job that recalculates rankings for all artists. Used for bulk recalculation operations triggered from the admin interface.

## Purpose
This job provides a way to trigger a complete artist ranking recalculation. Common use cases:
- Initial ranking calculation after creating a new ranking configuration
- Full refresh after album or song rankings have been updated
- Manual refresh triggered by admin to ensure rankings are current

## Public Methods

### `#perform(ranking_configuration_id)`
Main entry point for the job, executed asynchronously by Sidekiq.

**Parameters:**
- `ranking_configuration_id` (Integer) - The ID of the artist ranking configuration to use

**Behavior:**
1. Finds the ranking configuration by ID
2. Calls `config.calculate_rankings` to recalculate ALL artists
3. Logs success or failure
4. Raises exception on failure (triggers Sidekiq retry)

**Returns:** `nil`

**Side Effects:**
- Recalculates rankings for ALL artists
- Updates `ranked_items` table with new ranks and scores
- Logs calculation result to Rails logger

**Raises:**
- `ActiveRecord::RecordNotFound` if configuration doesn't exist
- `RuntimeError` if calculation fails (triggers Sidekiq retry mechanism)

**Example:**
```ruby
# Enqueue the job
config = Music::Artists::RankingConfiguration.default_primary
Music::CalculateAllArtistsRankingsJob.perform_async(config.id)

# In Avo action:
Music::CalculateAllArtistsRankingsJob.perform_async(config.id)
```

## Difference from CalculateArtistRankingJob

| Feature | CalculateArtistRankingJob | CalculateAllArtistsRankingsJob |
|---------|---------------------------|--------------------------------|
| Triggered by | Single artist update | Manual bulk refresh |
| Takes parameter | `artist_id` (for reference only) | `ranking_configuration_id` |
| Artists calculated | All artists | All artists |
| Typical use case | Admin action on artist show page | Admin action on artist index page |
| User intent | "Update this artist's rank" | "Refresh all artist rankings" |

**Note:** Both jobs calculate ALL artists because rankings are relative. The `artist_id` in the other job is only used for logging.

## Error Handling

**Configuration Not Found:**
- Raises `ActiveRecord::RecordNotFound`
- Sidekiq will retry (but will keep failing)
- Indicates data integrity issue (deleted configuration)

**Calculation Failure:**
- Logs error to Rails logger
- Raises exception with error message
- Sidekiq will retry job based on retry configuration

**Missing Album/Song Configurations:**
- Calculator returns success but with zero artists ranked
- Logs success (but no artists in result)
- Admin should check that album and song ranking configurations exist

## Logging

**Success:**
```
INFO -- : Successfully calculated all artists rankings for configuration 1
```

**Failure:**
```
ERROR -- : Failed to calculate all artists rankings: ["No albums configuration found"]
RuntimeError: All artists ranking calculation failed: No albums configuration found
```

## Performance

**Expected Duration:**
- ~100 artists: < 1 second
- ~1,000 artists: ~5 seconds
- ~10,000 artists: < 5 minutes

**Resource Usage:**
- Database: Heavy read queries (fetch all artists, albums, songs, ranked items)
- Database: Bulk write operations (upsert ranked_items)
- Memory: Moderate (processes artists in batches with `find_each`)

**Optimization:**
- Uses `find_each` for memory-efficient iteration
- Uses `upsert_all` for bulk database updates
- Uses transaction for atomicity

## Sidekiq Configuration

**Queue:** Default Sidekiq queue

**Retry:** Uses Sidekiq default retry policy (25 retries over ~21 days)

**Concurrency:** Can run concurrently with other jobs, but multiple instances of this job may cause lock contention on `ranked_items` table

**Recommendation:** Avoid enqueueing multiple instances of this job simultaneously (last one wins)

## Usage in Avo Admin

**Trigger Location:** Artist index page

**Action:** `Avo::Actions::Music::RefreshAllArtistsRankings`

**User Experience:**
1. Admin clicks "Refresh All Artists Rankings" on artist index page
2. Action enqueues this job with configuration ID
3. Success message: "All artists ranking calculation queued. This will process in the background."
4. Job runs in background
5. Rankings update within 1-5 minutes (depending on artist count)

## When to Use This Job

**Use this job when:**
- Creating a new artist ranking configuration for the first time
- Album or song rankings have been updated and artist rankings need to be refreshed
- Suspecting artist rankings are stale or incorrect
- After database migrations or data imports

**Don't use this job when:**
- Only a single artist's data changed (use `CalculateArtistRankingJob` instead)
- Wanting to recalculate frequently (can overwhelm database)

**Best Practice:** Schedule this job to run nightly or weekly rather than on-demand.

## Dependencies

**Models:**
- `Music::Artists::RankingConfiguration` - Configuration for ranking calculation

**Services:**
- `ItemRankings::Music::Artists::Calculator` - Called via `config.calculate_rankings`

**Database Tables:**
- `music_artists` - Artist data
- `music_albums` - Album data (for score aggregation)
- `music_songs` - Song data (for score aggregation)
- `ranking_configurations` - Configuration data
- `ranked_items` - Ranking results (updated)

## Related Jobs
- `Music::CalculateArtistRankingJob` - Single artist-triggered recalculation

## Related Documentation
- [Music::Artists::RankingConfiguration](/home/shane/dev/the-greatest/docs/models/music/artists/ranking_configuration.md)
- [ItemRankings::Music::Artists::Calculator](/home/shane/dev/the-greatest/docs/lib/item_rankings/music/artists/calculator.md)
- [Avo::Actions::Music::RefreshAllArtistsRankings](/home/shane/dev/the-greatest/docs/avo/actions/music/refresh_all_artists_rankings.md)
