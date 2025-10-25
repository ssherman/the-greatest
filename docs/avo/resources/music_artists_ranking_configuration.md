# Avo::Resources::MusicArtistsRankingConfiguration

## Summary
Avo admin resource for managing artist ranking configurations. Extends the base `Avo::Resources::RankingConfiguration` and customizes associations specific to artist rankings.

## Purpose
Provides admin interface for:
- Creating and editing artist ranking configurations
- Viewing ranked artists
- Triggering ranking calculations
- Managing configuration settings

## Inheritance
Extends `Avo::Resources::RankingConfiguration` which provides:
- Standard ranking configuration fields (name, description, primary, global, etc.)
- Configuration parameters (exponent, bonus_pool_percentage, etc.)
- Timestamps and metadata

## Model
Represents `Music::Artists::RankingConfiguration` model.

## Fields

### Inherited Fields
All fields from base `RankingConfiguration` resource:
- `name` - Configuration name (e.g., "Global Artist Rankings")
- `description` - Optional description text
- `type` - STI type (automatically set to "Music::Artists::RankingConfiguration")
- `primary` - Boolean flag (only one primary config allowed)
- `global` - Boolean flag (global vs user-specific)
- `published_at` - Publication timestamp
- `archived` - Boolean flag for archived configs
- `user` - Belongs to association (for user-specific rankings)
- `ranked_items` - Has many association (the calculated artist rankings)
- `penalties` - Has many association (penalties to apply)

### Overridden Fields

**`inherited_from`**
Belongs to association using the same resource type.
```ruby
field :inherited_from,
  as: :belongs_to,
  use_resource: Avo::Resources::MusicArtistsRankingConfiguration
```

### Fields NOT Used for Artists

**Mapped Lists:**
Unlike albums and songs, artist rankings don't use mapped lists. The following fields from the base resource are **not applicable**:
- `primary_mapped_list` - Not used (artists aggregate from album/song rankings)
- `secondary_mapped_list` - Not used
- `ranked_lists` - Not used (artists don't map to external lists)

**Configuration Parameters:**
The following fields are inherited but **not used** by artist rankings:
- `exponent` - Only applies to weighted_list_rank gem (not used for artists)
- `bonus_pool_percentage` - Only applies to weighted_list_rank gem (not used for artists)
- `list_limit` - Only applies to list-based ranking (not used for artists)

These fields are present in the form but don't affect artist ranking calculations.

## Actions

### Show Page Actions
**`Avo::Actions::Music::RefreshArtistRanking`**
- Appears on individual artist records (not ranking configuration)
- Triggers recalculation of all artist rankings
- Requires selecting a single artist
- Visibility: Show page only (`self.visible = -> { view.show? }`)

### Index Page Actions
**`Avo::Actions::Music::RefreshAllArtistsRankings`**
- Appears on artist index page (not ranking configuration index)
- Triggers bulk recalculation of all artists
- No record selection required (standalone action)
- Visibility: Index page only (`self.visible = -> { view.index? }`)

**Note:** These actions are registered on `Avo::Resources::MusicArtist`, not on this resource.

## URL Structure
**Admin Path:** `/avo/resources/music_artists_ranking_configurations`

**Show Page:** `/avo/resources/music_artists_ranking_configurations/:id`

**Edit Page:** `/avo/resources/music_artists_ranking_configurations/:id/edit`

**New Page:** `/avo/resources/music_artists_ranking_configurations/new`

## Usage

### Creating a New Artist Ranking Configuration
1. Navigate to `/avo/resources/music_artists_ranking_configurations/new`
2. Fill in required fields:
   - Name (e.g., "Global Artist Rankings")
   - Description (optional)
   - Check "Primary" if this should be the default
   - Check "Global" for global ranking
3. Click "Save"
4. Configuration is created but no artists are ranked yet
5. Navigate to artist index and run "Refresh All Artists Rankings" action

### Viewing Ranked Artists
1. Navigate to ranking configuration show page
2. Click "Ranked Items" association
3. View all artists with their ranks and scores
4. Sort by rank, score, or other fields

### Triggering Ranking Calculation
1. Navigate to artist index (`/avo/resources/music_artists`)
2. Click "Refresh All Artists Rankings" action
3. Confirm the action
4. Job is enqueued and runs in background
5. Refresh page after a few minutes to see updated rankings

## Special Considerations

### Aggregation vs List-Based
Artist ranking configurations work differently from album/song configurations:

**Albums/Songs:**
- Have `primary_mapped_list_id` and `secondary_mapped_list_id`
- Use `ranked_lists` to map to external lists
- Use weighted_list_rank gem for calculation
- Configuration parameters (exponent, bonus_pool) affect calculation

**Artists:**
- No mapped lists (aggregate from album/song rankings)
- No `ranked_lists` association used
- Custom calculator that sums scores from other configs
- Configuration parameters are ignored

### Dependencies
Artist rankings require:
1. A primary album ranking configuration with ranked albums
2. A primary song ranking configuration with ranked songs

If either is missing, artist ranking calculation will produce zero results.

## Related Resources
- `Avo::Resources::RankingConfiguration` (base resource)
- `Avo::Resources::MusicArtist` (artists that get ranked)
- `Avo::Resources::MusicAlbumsRankingConfiguration` (source of album scores)
- `Avo::Resources::MusicSongsRankingConfiguration` (source of song scores)

## Related Documentation
- [Music::Artists::RankingConfiguration](/home/shane/dev/the-greatest/docs/models/music/artists/ranking_configuration.md)
- [Avo::Actions::Music::RefreshArtistRanking](/home/shane/dev/the-greatest/docs/avo/actions/music/refresh_artist_ranking.md)
- [Avo::Actions::Music::RefreshAllArtistsRankings](/home/shane/dev/the-greatest/docs/avo/actions/music/refresh_all_artists_rankings.md)
