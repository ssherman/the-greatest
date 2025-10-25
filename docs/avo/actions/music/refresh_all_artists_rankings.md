# Avo::Actions::Music::RefreshAllArtistsRankings

## Summary
Avo admin action that triggers bulk recalculation of all artist rankings. Appears on the artist index page in the Avo admin interface as a standalone action.

## Purpose
Provides a convenient way for admins to trigger a complete refresh of all artist rankings. Typically used:
- After album or song rankings have been updated
- During initial setup of artist rankings
- When rankings appear stale or incorrect
- After database migrations or data imports

## Action Configuration

**Name:** "Refresh All Artists Rankings"

**Message:** "This will recalculate rankings for all artists based on their albums and songs. This process runs in the background and may take several minutes."

**Confirm Button:** "Refresh All Rankings"

**Standalone:** `true` (runs without requiring record selection)

**Visibility:** Index page only (`self.visible = -> { view.index? }`)

## Visibility

This action only appears on:
- Artist index page (`/avo/resources/music_artists`)

This action does NOT appear on:
- Artist show pages
- Other resource pages

**Avo 3.x Pattern:** Visibility is controlled via `self.visible = -> { view.index? }` in the action class, not in the resource registration.

## Standalone Action

**What is a Standalone Action?**

`self.standalone = true` means this action:
- Runs without requiring any records to be selected
- Does not receive a query of selected records
- Operates on the entire dataset (all artists)
- Shows as a button in the page header (not in row actions)

Without `standalone`, the action would:
- Require selecting one or more artists
- Only appear in the "Actions" dropdown after selection
- Not work for bulk operations without selection

## Behavior

### `#handle(query:, fields:, current_user:, resource:, **args)`

**Parameters:**
- `query` - ActiveRecord relation (not used, since action is standalone)
- `fields` - Form fields (not used by this action)
- `current_user` - Current admin user (not used by this action)
- `resource` - The Avo resource (not used by this action)

**Execution Flow:**
1. Fetches the default primary artist ranking configuration
2. Returns error if no configuration exists
3. Enqueues `Music::CalculateAllArtistsRankingsJob` with configuration ID
4. Returns success message

**Returns:** Avo action result (success or error)

**Success Message:** "All artists ranking calculation queued. This will process in the background."

**Error Message:** "No default artist ranking configuration found. Please create one first."

## Configuration Requirements

**Requires:** A default primary artist ranking configuration must exist.

```ruby
config = Music::Artists::RankingConfiguration.default_primary
```

If no configuration exists:
- Action returns error immediately
- No job is enqueued
- Admin should create configuration first at `/avo/resources/music_artists_ranking_configurations/new`

**Additional Requirements:**
- Primary album ranking configuration must exist and have ranked albums
- Primary song ranking configuration must exist and have ranked songs

Without these, the job will succeed but produce zero ranked artists.

## Background Job

**Job:** `Music::CalculateAllArtistsRankingsJob`

**Parameters:** `config.id` (ranking configuration ID)

**Expected Duration:**
- ~100 artists: < 1 second
- ~1,000 artists: ~5 seconds
- ~10,000 artists: < 5 minutes

**Side Effects:**
- Recalculates rankings for ALL artists
- Updates `ranked_items` table (creates, updates, deletes records)
- Logs calculation results to Rails logger

**Resource Usage:**
- Database: Heavy read operations (all artists, albums, songs, ranked items)
- Database: Bulk write operations (upsert ranked_items)
- Memory: Moderate (uses `find_each` for batching)

## User Experience

**Admin Workflow:**
1. Admin navigates to artist index (`/avo/resources/music_artists`)
2. Admin clicks "Refresh All Artists Rankings" button in page header
3. Confirmation modal appears with warning about background processing
4. Admin clicks "Refresh All Rankings" to confirm
5. Success toast appears: "All artists ranking calculation queued"
6. Admin can continue working (job runs in background)
7. After 1-5 minutes, all artist rankings are updated
8. Admin can view updated rankings at `/artists` (public site) or via ranked_items association

**Typical Use Cases:**
- Initial setup after creating artist ranking configuration
- After running "Refresh All Rankings" for albums or songs
- Monthly/weekly maintenance to ensure rankings are current
- After data imports or database migrations
- After discovering ranking anomalies

## When to Use vs RefreshArtistRanking

| Scenario | Use This Action | Use RefreshArtistRanking |
|----------|----------------|--------------------------|
| Initial setup | ✓ | |
| After album/song ranking updates | ✓ | |
| Monthly maintenance | ✓ | |
| Single artist data changed | | ✓ |
| Artist metadata updated | | ✓ |
| Albums added to one artist | | ✓ |

**Note:** Both actions recalculate ALL artists (rankings are relative). The difference is in the trigger:
- This action: Explicit bulk refresh
- Other action: Triggered by specific artist update

## Error Handling

**Missing Configuration:**
```ruby
unless config
  return error "No default artist ranking configuration found. Please create one first."
end
```

**Job Failure:**
- Job logs error and raises exception
- Sidekiq will retry job based on retry policy
- Admin can check Sidekiq web UI at `/sidekiq-admin` for job status

**Concurrent Execution:**
- Multiple admins triggering this action simultaneously
- Last job to complete will overwrite previous results
- Generally safe but may cause confusion
- Consider rate limiting or locks for production

## Registration

**Registered in:** `Avo::Resources::MusicArtist`

```ruby
action Avo::Actions::Music::RefreshAllArtistsRankings
```

## Best Practices

**Frequency:**
- Don't run this action too frequently (can overwhelm database)
- Recommended: Once after album/song ranking updates
- Consider scheduling via cron instead of manual triggering

**Timing:**
- Run during low-traffic periods if possible
- Expect 1-5 minutes of elevated database load
- Monitor Sidekiq queue depth

**Monitoring:**
- Check Sidekiq web UI for job progress
- Review Rails logs for success/failure messages
- Verify ranked_items count after completion

## Sidekiq Monitoring

**Check Job Status:**
1. Navigate to `/sidekiq-admin`
2. Look for `Music::CalculateAllArtistsRankingsJob` in queue
3. Monitor "Processed" count
4. Check "Failed" tab if job doesn't complete

**Logs:**
```
# Success
INFO -- : Successfully calculated all artists rankings for configuration 1

# Failure
ERROR -- : Failed to calculate all artists rankings: ["No albums configuration found"]
```

## Related Actions
- `Avo::Actions::Music::RefreshArtistRanking` - Single artist-triggered recalculation

## Dependencies
- `Music::CalculateAllArtistsRankingsJob` - Background job that performs calculation
- `Music::Artists::RankingConfiguration` - Configuration model
- `ItemRankings::Music::Artists::Calculator` - Service that calculates rankings

## Related Documentation
- [Music::CalculateAllArtistsRankingsJob](/home/shane/dev/the-greatest/docs/sidekiq/music/calculate_all_artists_rankings_job.md)
- [Music::Artists::RankingConfiguration](/home/shane/dev/the-greatest/docs/models/music/artists/ranking_configuration.md)
- [ItemRankings::Music::Artists::Calculator](/home/shane/dev/the-greatest/docs/lib/item_rankings/music/artists/calculator.md)
