# Music::CalculateArtistRankingJob

## Summary
Sidekiq background job that recalculates artist rankings when triggered by a single artist update. Despite being triggered by a specific artist, this job recalculates ALL artist rankings because rankings are relative (one artist's rank depends on all other artists' scores).

## Purpose
This job provides a way to trigger artist ranking recalculation from the admin interface when an artist's data changes. Common triggers:
- Admin uses "Refresh Artist Ranking" action on an artist
- Artist's albums or songs are updated
- Album or song rankings change, affecting artist scores

## Public Methods

### `#perform(artist_id)`
Main entry point for the job, executed asynchronously by Sidekiq.

**Parameters:**
- `artist_id` (Integer) - The ID of the artist that triggered this recalculation

**Behavior:**
1. Finds the artist by ID (validates artist exists)
2. Fetches the default primary artist ranking configuration
3. Returns early if no configuration exists (graceful degradation)
4. Calls `config.calculate_rankings` to recalculate ALL artists
5. Logs success or failure
6. Raises exception on failure (triggers Sidekiq retry)

**Returns:** `nil`

**Side Effects:**
- Recalculates rankings for ALL artists (not just the specified artist)
- Updates `ranked_items` table with new ranks and scores
- Logs calculation result to Rails logger

**Raises:** `RuntimeError` if calculation fails (triggers Sidekiq retry mechanism)

**Example:**
```ruby
# Enqueue the job
Music::CalculateArtistRankingJob.perform_async(artist.id)

# In Avo action:
Music::CalculateArtistRankingJob.perform_async(query.first.id)
```

## Why Recalculate All Artists?

**Question:** Why recalculate all artists when only one artist changed?

**Answer:** Artist rankings are **relative**, not absolute. An artist's rank depends on how their score compares to all other artists' scores. If one artist's score changes, it can affect the ranks of many other artists.

**Example:**
```
Before:
#1: Beatles (1000 pts)
#2: Pink Floyd (950 pts)
#3: Led Zeppelin (900 pts)

After Pink Floyd adds a highly-ranked album:
#1: Pink Floyd (1050 pts)   <- rank changed
#2: Beatles (1000 pts)        <- rank changed
#3: Led Zeppelin (900 pts)    <- rank unchanged
```

## Configuration Requirements

**Requires:** A default primary artist ranking configuration must exist.

```ruby
# Check if configuration exists
config = Music::Artists::RankingConfiguration.default_primary
# => Returns configuration or nil
```

If no configuration exists:
- Job returns early without error
- No rankings are calculated
- Admin should create configuration first

## Error Handling

**Missing Configuration:** Returns early (no error raised)

**Calculation Failure:**
- Logs error to Rails logger
- Raises exception with error message
- Sidekiq will retry job based on retry configuration

**Artist Not Found:**
- Raises `ActiveRecord::RecordNotFound`
- Sidekiq will retry (but will keep failing)
- Indicates data integrity issue

## Logging

**Success:**
```
INFO -- : Successfully calculated artist rankings (triggered by artist 123)
```

**Failure:**
```
ERROR -- : Failed to calculate artist rankings: ["Configuration missing album config"]
RuntimeError: Artist ranking calculation failed: Configuration missing album config
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

## Sidekiq Configuration

**Queue:** Default Sidekiq queue

**Retry:** Uses Sidekiq default retry policy (25 retries over ~21 days)

**Concurrency:** Can run concurrently with other jobs, but multiple instances of this job may cause lock contention on `ranked_items` table

## Usage in Avo Admin

**Trigger Location:** Artist show page

**Action:** `Avo::Actions::Music::RefreshArtistRanking`

**User Experience:**
1. Admin clicks "Refresh Artist Ranking" on artist show page
2. Action enqueues this job with artist ID
3. Success message: "Artist ranking calculation queued for [Artist Name]"
4. Job runs in background
5. Rankings update within 1-5 minutes (depending on artist count)

## Dependencies

**Models:**
- `Music::Artist` - The artist being referenced
- `Music::Artists::RankingConfiguration` - Configuration for ranking calculation

**Services:**
- `ItemRankings::Music::Artists::Calculator` - Called via `config.calculate_rankings`

**Database Tables:**
- `music_artists` - Artist data
- `ranking_configurations` - Configuration data
- `ranked_items` - Ranking results (updated)

## Related Jobs
- `Music::CalculateAllArtistsRankingsJob` - Bulk recalculation without artist reference

## Related Documentation
- [Music::Artists::RankingConfiguration](/home/shane/dev/the-greatest/docs/models/music/artists/ranking_configuration.md)
- [ItemRankings::Music::Artists::Calculator](/home/shane/dev/the-greatest/docs/lib/item_rankings/music/artists/calculator.md)
- [Avo::Actions::Music::RefreshArtistRanking](/home/shane/dev/the-greatest/docs/avo/actions/music/refresh_artist_ranking.md)
