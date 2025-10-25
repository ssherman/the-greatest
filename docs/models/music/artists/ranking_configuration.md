# Music::Artists::RankingConfiguration

## Summary
Represents a ranking configuration specifically for music artists. Uses Single Table Inheritance (STI) extending the base `RankingConfiguration` model. Unlike album and song rankings which use list-based aggregation, artist rankings aggregate scores from both album and song rankings to create a comprehensive artist ranking.

## Associations
- Inherits all associations from `RankingConfiguration`:
  - `has_many :ranked_items` - The calculated artist rankings (rank and score for each artist)
  - `has_many :ranked_lists` - **Not used** for artists (artists use aggregation, not list-based ranking)
  - `has_many :penalties` - Penalties that can be applied to this configuration
  - `belongs_to :user` (optional) - User who owns this configuration (for user-specific rankings)
  - `belongs_to :inherited_from` (optional) - Parent configuration if inheriting settings

## Key Characteristics

### Aggregation-Based Ranking
Artist rankings differ from albums/songs in a fundamental way:
- **Albums/Songs**: Aggregate from mapped lists (e.g., "Rolling Stone's 500 Greatest Albums")
- **Artists**: Aggregate from TWO other ranking configurations (album rankings + song rankings)

This means:
- No `ranked_lists` association is used
- No `primary_mapped_list` or `secondary_mapped_list` is set
- The calculator fetches scores from `Music::Albums::RankingConfiguration.default_primary` and `Music::Songs::RankingConfiguration.default_primary`

### Dual Configuration Dependency
Artist rankings depend on:
1. The primary album ranking configuration (for album scores)
2. The primary song ranking configuration (for song scores)

If either of these configurations is missing or empty, artist rankings cannot be calculated.

### URL Structure
Unlike albums/songs which use `/rc/:id/albums` or `/rc/:id/songs`, artist rankings use a simpler URL:
- **Albums**: `/albums` or `/rc/:id/albums` (supports ranking configuration parameter)
- **Songs**: `/songs` or `/rc/:id/songs` (supports ranking configuration parameter)
- **Artists**: `/artists` (always uses default primary configs, no rc parameter)

This is because artists need TWO config IDs (albums and songs), not one, so the URL parameter approach doesn't work.

## Public Methods

### Inherited from RankingConfiguration

**`#calculate_rankings`**
Triggers the artist ranking calculation by instantiating `ItemRankings::Music::Artists::Calculator` and calling its `call` method.
- Returns: `Result` struct with `success?`, `data`, and `errors` attributes
- Side effect: Creates/updates `RankedItem` records for artists

**`.default_primary`**
Class method to find the default primary artist ranking configuration.
- Returns: `Music::Artists::RankingConfiguration` instance or nil
- Scope: `where(type: 'Music::Artists::RankingConfiguration', primary: true, global: true).first`

## Validations
Inherits all validations from `RankingConfiguration`:
- `name` - presence, uniqueness (scoped to type and user_id)
- `type` - presence
- `exponent` - numericality (not used for artists, but inherited)
- `bonus_pool_percentage` - numericality (not used for artists, but inherited)

## Scopes
Inherits all scopes from `RankingConfiguration`:
- `primary` - Configurations marked as primary
- `global` - Global configurations (not user-specific)
- `published` - Configurations with a published_at date

## Attributes

### Inherited Attributes (Not Used for Artists)
The following attributes are inherited from `RankingConfiguration` but are **not used** by artist rankings since they don't use the weighted_list_rank gem:
- `exponent` - Controls list weight decay (not applicable)
- `bonus_pool_percentage` - Bonus points for top items (not applicable)
- `primary_mapped_list_id` - Primary list to aggregate from (not used)
- `secondary_mapped_list_id` - Secondary list to aggregate from (not used)
- `list_limit` - Max number of lists to consider (not applicable)

### Attributes Used for Artists
- `type` - Always `"Music::Artists::RankingConfiguration"`
- `name` - Display name (e.g., "Global Artist Rankings")
- `description` - Optional description
- `primary` - Boolean flag indicating if this is the primary artist ranking
- `global` - Boolean flag indicating if this is a global ranking (vs user-specific)
- `published_at` - Timestamp when ranking was published

## Calculator
Uses `ItemRankings::Music::Artists::Calculator` for calculation logic.

See: [ItemRankings::Music::Artists::Calculator](/home/shane/dev/the-greatest/docs/lib/item_rankings/music/artists/calculator.md)

## Background Jobs
- `Music::CalculateArtistRankingJob` - Recalculates all artists when triggered by single artist update
- `Music::CalculateAllArtistsRankingsJob` - Bulk recalculation of all artist rankings

## Avo Admin Interface
- Resource: `Avo::Resources::MusicArtistsRankingConfiguration`
- Actions:
  - `Avo::Actions::Music::RefreshArtistRanking` (show page only)
  - `Avo::Actions::Music::RefreshAllArtistsRankings` (index page only)

## Usage Example

```ruby
# Find the default primary artist ranking configuration
config = Music::Artists::RankingConfiguration.default_primary

# Trigger ranking calculation
result = config.calculate_rankings

if result.success?
  puts "Successfully calculated #{result.data.count} artist rankings"
else
  puts "Errors: #{result.errors.join(', ')}"
end

# Access the ranked items
config.ranked_items.order(:rank).limit(10).each do |ranked_item|
  artist = ranked_item.item
  puts "##{ranked_item.rank}: #{artist.name} (Score: #{ranked_item.score})"
end
```

## Dependencies
- Base class: `RankingConfiguration`
- Calculator: `ItemRankings::Music::Artists::Calculator`
- Models: `Music::Artist`, `Music::Albums::RankingConfiguration`, `Music::Songs::RankingConfiguration`
- Database tables: `ranking_configurations`, `ranked_items`

## Related Documentation
- [RankingConfiguration](/home/shane/dev/the-greatest/docs/models/ranking_configuration.md)
- [RankedItem](/home/shane/dev/the-greatest/docs/models/ranked_item.md)
- [ItemRankings::Music::Artists::Calculator](/home/shane/dev/the-greatest/docs/lib/item_rankings/music/artists/calculator.md)
- [Music::Artist](/home/shane/dev/the-greatest/docs/models/music/artist.md)
