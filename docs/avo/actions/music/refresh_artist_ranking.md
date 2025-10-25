# Avo::Actions::Music::RefreshArtistRanking

## Summary
Avo admin action that triggers artist ranking recalculation when an individual artist is updated. Appears on the artist show page in the Avo admin interface.

## Purpose
Provides a convenient way for admins to trigger artist ranking recalculation after an artist's data has changed (e.g., new albums added, artist metadata updated).

## Action Configuration

**Name:** "Refresh Artist Ranking"

**Message:** "This will recalculate this artist's ranking based on their albums and songs."

**Confirm Button:** "Refresh Ranking"

**Standalone:** `true` (can run without record selection)

**Visibility:** Show page only (`self.visible = -> { view.show? }`)

## Visibility

This action only appears on:
- Artist show pages (`/avo/resources/music_artists/:id`)

This action does NOT appear on:
- Artist index page
- Other resource pages

**Avo 3.x Pattern:** Visibility is controlled via `self.visible = -> { view.show? }` in the action class, not in the resource registration.

## Behavior

### `#handle(query:, fields:, current_user:, resource:, **args)`

**Parameters:**
- `query` - ActiveRecord relation containing selected artists
- `fields` - Form fields (not used by this action)
- `current_user` - Current admin user (not used by this action)
- `resource` - The Avo resource (not used by this action)

**Execution Flow:**
1. Extracts the first artist from query
2. Validates only one artist is selected
3. Enqueues `Music::CalculateArtistRankingJob` with artist ID
4. Returns success message with artist name

**Returns:** Avo action result (success or error)

**Success Message:** "Artist ranking calculation queued for [Artist Name]. Rankings will be updated in the background."

**Error Message:** "This action can only be performed on a single artist." (if multiple artists selected)

## Important Note: Recalculates ALL Artists

**User Expectation:** "Refresh this artist's ranking"

**Actual Behavior:** Recalculates ALL artist rankings

**Why?** Artist rankings are relative. An artist's rank depends on all other artists' scores. When one artist's score changes, it can affect the ranks of many other artists.

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

## Background Job

**Job:** `Music::CalculateArtistRankingJob`

**Parameters:** `artist.id`

**Duration:** 1-5 minutes (depending on total artist count)

**Side Effects:**
- Recalculates ALL artist rankings (not just the selected artist)
- Updates `ranked_items` table
- Logs calculation results

## User Experience

**Admin Workflow:**
1. Admin edits an artist (adds albums, updates metadata, etc.)
2. Admin clicks "Refresh Artist Ranking" button
3. Confirmation modal appears with message
4. Admin clicks "Refresh Ranking" to confirm
5. Success toast appears: "Artist ranking calculation queued for [Name]"
6. Admin can continue working (job runs in background)
7. After 1-5 minutes, artist rankings are updated
8. Admin refreshes artist show page to see new rank

**Typical Use Cases:**
- After adding new albums to an artist
- After album or song rankings have been updated
- After fixing artist data errors
- After merging duplicate artists

## Error Handling

**Multiple Artists Selected:**
- Returns error: "This action can only be performed on a single artist."
- Should not happen in normal usage (show page only shows one artist)
- Guards against edge cases

**Missing Configuration:**
- Job returns early without error
- No rankings calculated
- Admin should create artist ranking configuration first

**Job Failure:**
- Job logs error and raises exception
- Sidekiq will retry job
- Admin can check Sidekiq web UI for job status

## Validation

**Single Artist Only:**
```ruby
if query.count > 1
  return error "This action can only be performed on a single artist."
end
```

This validation ensures the action is only used on individual artists, not in bulk operations.

## Registration

**Registered in:** `Avo::Resources::MusicArtist`

```ruby
action Avo::Actions::Music::RefreshArtistRanking
```

## Related Actions
- `Avo::Actions::Music::RefreshAllArtistsRankings` - Bulk recalculation for all artists

## Dependencies
- `Music::CalculateArtistRankingJob` - Background job that performs calculation
- `Music::Artists::RankingConfiguration` - Configuration used by job
- `ItemRankings::Music::Artists::Calculator` - Service that calculates rankings

## Related Documentation
- [Music::CalculateArtistRankingJob](/home/shane/dev/the-greatest/docs/sidekiq/music/calculate_artist_ranking_job.md)
- [Music::Artists::RankingConfiguration](/home/shane/dev/the-greatest/docs/models/music/artists/ranking_configuration.md)
- [ItemRankings::Music::Artists::Calculator](/home/shane/dev/the-greatest/docs/lib/item_rankings/music/artists/calculator.md)
