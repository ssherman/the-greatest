# 061 - Artist Rankings Implementation

## Status
- **Status**: Completed
- **Priority**: High
- **Created**: 2025-10-24
- **Started**: 2025-10-24
- **Completed**: 2025-10-25
- **Developer**: Claude Code

## Overview
Implement a comprehensive artist ranking system that aggregates scores from both albums and songs associated with each artist. This will create "The Greatest Artists" rankings based on the quality and acclaim of their musical output across both albums and individual songs.

## Context

### Business Context
Artists are the cornerstone of music curation. While we have rankings for albums and songs, we lack a unified view of which artists have created the most acclaimed body of work. An artist ranking system will:

1. **Provide holistic artist evaluation** - Combine both album and song rankings to show artists' full impact
2. **Enable artist discovery** - Users can find the most acclaimed artists across all time
3. **Support editorial content** - Create "Greatest Artists" lists and features
4. **Improve navigation** - Add artists as a top-level browsable category alongside albums and songs

### Technical Context
The codebase has a well-established pattern for rankings using the `RankingConfiguration` / `RankedItem` architecture:

- `RankingConfiguration` (STI) - Defines ranking algorithm parameters
- `RankedItem` (polymorphic) - Stores rank/score for individual items
- `ItemRankings::Calculator` - Base service for calculating rankings
- Domain-specific calculators - Extend base for each item type

**Examples in codebase**:
- `Music::Albums::RankingConfiguration` + `ItemRankings::Music::Albums::Calculator`
- `Music::Songs::RankingConfiguration` + `ItemRankings::Music::Songs::Calculator`
- `Books::RankingConfiguration` + `ItemRankings::Books::Calculator`

### Artist Rankings Approach

Artist rankings will follow the same established pattern used for albums, songs, books, movies, and games:

```ruby
# Rankings stored in polymorphic ranked_items table
has_many :ranked_items, as: :item, dependent: :destroy

# RankedItem schema:
# - item_id (bigint)
# - item_type (string) - "Music::Artist"
# - ranking_configuration_id (bigint)
# - rank (integer)
# - score (decimal)
```

**Benefits of this pattern**:
1. **Multiple ranking configurations** - Can have different artist rankings (all-time, by decade, by genre, user-specific)
2. **Consistent architecture** - Same pattern across all domains
3. **Historical tracking** - Can preserve old rankings when creating new configurations
4. **User personalization** - Each user can have their own artist rankings
5. **Flexible algorithms** - Different configs can use different weighting/penalties
6. **Database normalization** - Rankings data separate from core artist data

**Note**: The primary artist ranking configuration will be created manually through the admin interface rather than via migration.

## Requirements

### Functional Requirements

#### Data Model
- [ ] Create `Music::Artists::RankingConfiguration` model (STI extending `RankingConfiguration`)
- [ ] Add `has_many :ranked_items, as: :item, dependent: :destroy` to `Music::Artist` model

#### Service Layer
- [ ] Create `ItemRankings::Music::Artists::Calculator` service class
- [ ] Implement artist score calculation algorithm:
  - Sum all scores from artist's albums (via `ranked_items`)
  - Sum all scores from artist's songs (via `ranked_items`)
  - Calculate total artist score as: `album_scores + song_scores`
- [ ] Create `Music::Artists::RankingService` for single artist calculation
- [ ] Support both single-artist and all-artists calculation modes

#### Background Jobs
- [ ] Create `Music::CalculateArtistRankingJob` for single artist
- [ ] Create `Music::CalculateAllArtistsRankingsJob` for bulk processing
- [ ] Jobs should use `CalculateRankingsJob` pattern (call calculator service)

#### Admin Interface (Avo Actions)
- [ ] Create `Avo::Actions::Music::RefreshArtistRanking` (show page only)
  - Enqueues single artist ranking job
  - Success message: "Artist ranking calculation queued"
- [ ] Create `Avo::Actions::Music::RefreshAllArtistsRankings` (index page only)
  - Enqueues job to recalculate all artists
  - Success message: "All artists ranking calculation queued (runs in background)"
- [ ] Register actions in `Avo::Resources::MusicArtist`

#### Public UI
- [ ] Add "Artists" menu item to music navigation
- [ ] Create `Music::Artists::RankedItemsController` (extends `Music::RankedItemsController`)
- [ ] Implement `index` action showing artists sorted by rank
  - Use pagination (100 per page, matching albums/songs pattern)
  - Include primary image, name, categories
  - Display rank and score
  - Link to artist show page
- [ ] Add route: `/artists` on music domain (outside rc scope, always uses default primary configs)

#### Controller Enhancement
- [ ] Update `Music::ArtistsController#show` to display artist's rank/score if ranked
  - Show rank badge (e.g., "Ranked #5 of Greatest Artists")
  - Include in metadata or header area

### Non-Functional Requirements
- [ ] All artist calculations should complete within 5 minutes for ~10,000 artists
- [ ] Use background jobs for all ranking calculations (never inline)
- [ ] Support incremental updates (single artist recalculation)
- [ ] Maintain consistency with existing ranking patterns
- [ ] Follow Rails 8 conventions and project code style

## Technical Approach

### Artist Ranking Algorithm

**Data Sources**:
1. **Album Rankings** - Get all `RankedItem` records where:
   - `item_type = 'Music::Album'`
   - `item_id IN (artist.albums.pluck(:id))`
   - `ranking_configuration_id = [primary album config]`

2. **Song Rankings** - Get all `RankedItem` records where:
   - `item_type = 'Music::Song'`
   - `item_id IN (artist.songs.pluck(:id))`
   - `ranking_configuration_id = [primary song config]`

**Calculation**:
```ruby
def calculate_artist_score(artist)
  # Get primary album ranking configuration
  album_config = Music::Albums::RankingConfiguration.default_primary

  # Get primary song ranking configuration
  song_config = Music::Songs::RankingConfiguration.default_primary

  # Sum album scores
  album_scores = RankedItem
    .where(item_type: 'Music::Album', item_id: artist.albums.pluck(:id))
    .where(ranking_configuration_id: album_config.id)
    .sum(:score)

  # Sum song scores
  song_scores = RankedItem
    .where(item_type: 'Music::Song', item_id: artist.songs.pluck(:id))
    .where(ranking_configuration_id: song_config.id)
    .sum(:score)

  # Total score
  total_score = album_scores + song_scores

  total_score
end
```

**Ranking Assignment**:
After calculating scores for all artists:
1. Sort by score descending
2. Assign rank 1, 2, 3, etc.
3. Upsert into `RankedItem` table

### File Structure

**Models**:
```
web-app/app/models/music/artists/
├── ranking_configuration.rb  # STI model extending RankingConfiguration
```

**Services**:
```
web-app/app/lib/item_rankings/music/artists/
├── calculator.rb  # Main ranking calculator service
```

**Jobs**:
```
web-app/app/sidekiq/music/
├── calculate_artist_ranking_job.rb      # Single artist
├── calculate_all_artists_rankings_job.rb # All artists
```

**Controllers**:
```
web-app/app/controllers/music/artists/
├── ranked_items_controller.rb  # Public rankings index
```

**Avo Actions**:
```
web-app/app/avo/actions/music/
├── refresh_artist_ranking.rb       # Single artist action
├── refresh_all_artists_rankings.rb # Bulk action
```

**Views**:
```
web-app/app/views/music/artists/ranked_items/
├── index.html.erb  # Artists rankings page
```

### Implementation Pattern Examples

#### 1. Ranking Configuration Model
```ruby
# web-app/app/models/music/artists/ranking_configuration.rb
module Music
  module Artists
    class RankingConfiguration < ::RankingConfiguration
      # Inherits all behavior from base RankingConfiguration
      # STI handles type differentiation
    end
  end
end
```

#### 2. Calculator Service
```ruby
# web-app/app/lib/item_rankings/music/artists/calculator.rb
module ItemRankings
  module Music
    module Artists
      class Calculator < ItemRankings::Calculator
        protected

        def list_type
          # Artists don't use traditional list-based ranking
          # Instead, they aggregate from album/song rankings
          raise NotImplementedError, "Artists use aggregation, not list-based ranking"
        end

        def item_type
          "Music::Artist"
        end

        # Override base calculation method
        def call
          artists_with_scores = calculate_all_artist_scores
          update_ranked_items_from_scores(artists_with_scores)

          Result.new(success?: true, data: artists_with_scores, errors: [])
        rescue => error
          Result.new(success?: false, data: nil, errors: [error.message])
        end

        private

        def calculate_all_artist_scores
          # Artist rankings aggregate from TWO other ranking configurations
          album_config = ::Music::Albums::RankingConfiguration.default_primary
          song_config = ::Music::Songs::RankingConfiguration.default_primary

          # Handle missing configurations gracefully
          return [] unless album_config && song_config

          # Get all artists with their album/song scores
          artists = ::Music::Artist.includes(:albums, :songs).find_each.map do |artist|
            {
              id: artist.id,
              score: calculate_artist_score(artist, album_config, song_config)
            }
          end

          # Sort by score descending
          artists.sort_by { |a| -a[:score] }
        end

        def calculate_artist_score(artist, album_config, song_config)
          album_scores = RankedItem
            .where(item_type: 'Music::Album', item_id: artist.albums.pluck(:id))
            .where(ranking_configuration_id: album_config.id)
            .sum(:score)

          song_scores = RankedItem
            .where(item_type: 'Music::Song', item_id: artist.songs.pluck(:id))
            .where(ranking_configuration_id: song_config.id)
            .sum(:score)

          album_scores + song_scores
        end

        def update_ranked_items_from_scores(artists_with_scores)
          ActiveRecord::Base.transaction do
            ranked_items_data = []

            artists_with_scores.each_with_index do |artist_data, index|
              next if artist_data[:score].zero? # Skip artists with no ranked content

              ranked_items_data << {
                ranking_configuration_id: ranking_configuration.id,
                item_id: artist_data[:id],
                item_type: 'Music::Artist',
                rank: index + 1,
                score: artist_data[:score],
                created_at: Time.current
              }
            end

            if ranked_items_data.any?
              RankedItem.upsert_all(
                ranked_items_data,
                unique_by: [:item_id, :item_type, :ranking_configuration_id],
                update_only: [:rank, :score]
              )
            end

            # Remove ranked_items for artists no longer in rankings
            current_artist_ids = artists_with_scores.map { |a| a[:id] }
            ranking_configuration.ranked_items
              .where(item_type: 'Music::Artist')
              .where.not(item_id: current_artist_ids)
              .delete_all
          end
        end
      end
    end
  end
end
```

#### 3. Background Job
```ruby
# web-app/app/sidekiq/music/calculate_artist_ranking_job.rb
module Music
  class CalculateArtistRankingJob
    include Sidekiq::Job

    def perform(artist_id)
      artist = Music::Artist.find(artist_id)
      config = Music::Artists::RankingConfiguration.default_primary

      return unless config

      # Recalculate all artists (artist rankings are relative)
      # Can't calculate one artist in isolation
      result = config.calculate_rankings

      if result.success?
        Rails.logger.info "Successfully calculated artist rankings (triggered by artist #{artist_id})"
      else
        Rails.logger.error "Failed to calculate artist rankings: #{result.errors}"
        raise "Artist ranking calculation failed: #{result.errors.join(", ")}"
      end
    end
  end
end
```

#### 4. Avo Action (Single Artist)
```ruby
# web-app/app/avo/actions/music/refresh_artist_ranking.rb
class Avo::Actions::Music::RefreshArtistRanking < Avo::BaseAction
  self.name = "Refresh Artist Ranking"
  self.message = "This will recalculate this artist's ranking based on their albums and songs."
  self.confirm_button_label = "Refresh Ranking"
  self.standalone = true

  def handle(query:, fields:, current_user:, resource:, **args)
    artist = query.first

    if query.count > 1
      return error "This action can only be performed on a single artist."
    end

    Music::CalculateArtistRankingJob.perform_async(artist.id)

    succeed "Artist ranking calculation queued for #{artist.name}. Rankings will be updated in the background."
  end
end
```

#### 5. Avo Action (All Artists)
```ruby
# web-app/app/avo/actions/music/refresh_all_artists_rankings.rb
class Avo::Actions::Music::RefreshAllArtistsRankings < Avo::BaseAction
  self.name = "Refresh All Artists Rankings"
  self.message = "This will recalculate rankings for all artists based on their albums and songs. This process runs in the background and may take several minutes."
  self.confirm_button_label = "Refresh All Rankings"

  def handle(query:, fields:, current_user:, resource:, **args)
    config = Music::Artists::RankingConfiguration.default_primary

    unless config
      return error "No default artist ranking configuration found. Please create one first."
    end

    Music::CalculateAllArtistsRankingsJob.perform_async(config.id)

    succeed "All artists ranking calculation queued. This will process in the background."
  end
end
```

#### 6. Ranked Items Controller
```ruby
# web-app/app/controllers/music/artists/ranked_items_controller.rb
class Music::Artists::RankedItemsController < ApplicationController
  include Pagy::Backend

  layout "music/application"

  def index
    # Artist rankings always use the default primary artist ranking configuration
    # NOTE: Unlike albums/songs, we don't accept a ranking_configuration_id parameter
    # because artist rankings aggregate from TWO configs (albums and songs).
    # The calculator always uses default_primary for both.
    @ranking_configuration = Music::Artists::RankingConfiguration.default_primary

    unless @ranking_configuration
      # If no artist ranking config exists yet, show empty state
      @artists = []
      @pagy = nil
      return
    end

    artists_query = @ranking_configuration.ranked_items
      .joins("JOIN music_artists ON ranked_items.item_id = music_artists.id AND ranked_items.item_type = 'Music::Artist'")
      .includes(item: [:categories, :primary_image])
      .where(item_type: "Music::Artist")
      .order(:rank)

    @pagy, @artists = pagy(artists_query, limit: 100)
  end
end
```

### Database Changes

**Model Association**:
```ruby
# web-app/app/models/music/artist.rb
class Music::Artist < ApplicationRecord
  # ... existing associations ...

  # Ranking associations
  has_many :ranked_items, as: :item, dependent: :destroy

  # ... rest of model ...
end
```

### Routes

```ruby
# config/routes.rb
# Music domain routes (using DomainConstraint)
constraints DomainConstraint.new(Rails.application.config.domains[:music]) do

  # Optional ranking configuration scope for albums/songs
  scope "(/rc/:ranking_configuration_id)" do
    get "albums", to: "music/albums/ranked_items#index", as: :albums
    get "songs", to: "music/songs/ranked_items#index", as: :songs
    get "artists/:id", to: "music/artists#show", as: :artist  # Existing route
  end

  # Artist rankings - OUTSIDE the rc scope
  # NOTE: Unlike albums/songs, artists is NOT scoped under ranking configuration
  # because artist rankings depend on TWO ranking configurations (albums and songs).
  # Always uses default primary configs for both.
  get "artists", to: "music/artists/ranked_items#index", as: :artists
end

# On thegreatestmusic.org domain:
# - /artists (artist rankings index, always uses default primary configs)
# - /albums (or /rc/5/albums with optional rc parameter)
# - /songs (or /rc/6/songs with optional rc parameter)
# - /artists/:id (artist show page, can use /rc/X/artists/:id)
```

**Note on URL Structure:**
Artist rankings use a different URL structure (`/artists`) compared to albums/songs which use the scoped `rc` parameter (`/rc/:id/albums`, `/rc/:id/songs`). This is because:

1. **Multi-Domain Architecture**: Routes use `DomainConstraint` to scope by domain (thegreatestmusic.org), not namespace. The URL is `/artists` on the music domain, not `/music/artists`.

2. **Dual Configuration Dependency**: Artist rankings aggregate from BOTH album and song ranking configurations, so a single `ranking_configuration_id` parameter doesn't make sense.

3. **Always Uses Primary Configs**: The artist calculator will always use:
   - `Music::Albums::RankingConfiguration.default_primary` for album scores
   - `Music::Songs::RankingConfiguration.default_primary` for song scores

4. **Simpler User Experience**: `/artists` is cleaner and more intuitive than trying to encode two config IDs in the URL.

The controller will NOT accept a `ranking_configuration_id` parameter and will always fetch the default primary configs in the calculator.

### UI Integration

**Navigation Menu Addition**:
```erb
<!-- Music domain navigation (on thegreatestmusic.org) -->
<li><%= link_to "Albums", albums_path %></li>
<li><%= link_to "Songs", songs_path %></li>
<li><%= link_to "Artists", artists_path %></li>
```

**Note**: All three navigation items use simple paths. On the music domain:
- `albums_path` → `/albums` (or `/rc/:id/albums` if rc parameter present)
- `songs_path` → `/songs` (or `/rc/:id/songs` if rc parameter present)
- `artists_path` → `/artists` (always, no rc parameter)

**Artist Show Page Enhancement**:
```erb
<!-- In artist show page -->
<% if @artist.ranked_items.exists? %>
  <% ranked_item = @artist.ranked_items.joins(:ranking_configuration).where(ranking_configurations: { primary: true }).first %>
  <% if ranked_item %>
    <div class="artist-ranking">
      Ranked #<%= ranked_item.rank %> of The Greatest Artists
      (Score: <%= number_with_precision(ranked_item.score, precision: 2) %>)
    </div>
  <% end %>
<% end %>
```

## Dependencies

### Models
- `Music::Artist` - Add `ranked_items` association
- `RankingConfiguration` - Base class for STI
- `RankedItem` - Stores artist rank/score
- `Music::Albums::RankingConfiguration` - Source of album scores
- `Music::Songs::RankingConfiguration` - Source of song scores

### Existing Services
- `ItemRankings::Calculator` - Base service to extend
- `Music::Albums::RankingConfiguration.default_primary` - Album ranking source
- `Music::Songs::RankingConfiguration.default_primary` - Song ranking source

### Background Jobs
- New: `Music::CalculateArtistRankingJob`
- New: `Music::CalculateAllArtistsRankingsJob`
- Pattern: `CalculateRankingsJob` (existing pattern to follow)

### Gems
- No new gems required
- Uses existing: `pagy`, `sidekiq`, `avo`

## Acceptance Criteria

### Data Model
- [ ] `Music::Artists::RankingConfiguration` model exists and inherits from `RankingConfiguration`
- [ ] `Music::Artist` has `has_many :ranked_items, as: :item, dependent: :destroy`
- [ ] `RankedItem` table properly stores artist rankings with correct polymorphic associations

### Service Layer
- [ ] `ItemRankings::Music::Artists::Calculator` service exists
- [ ] Calculator correctly sums album scores from primary album ranking configuration
- [ ] Calculator correctly sums song scores from primary song ranking configuration
- [ ] Calculator creates total artist score as `album_scores + song_scores`
- [ ] Calculator assigns ranks in descending score order
- [ ] Calculator upserts `RankedItem` records for all artists
- [ ] Calculator handles artists with no ranked content (zero scores)
- [ ] Service returns `Result` struct with success/failure status

### Background Jobs
- [ ] `Music::CalculateArtistRankingJob` exists and enqueues successfully
- [ ] `Music::CalculateAllArtistsRankingsJob` exists and enqueues successfully
- [ ] Jobs call calculator service and handle errors
- [ ] Jobs log success/failure appropriately
- [ ] Jobs complete within reasonable time (< 5 minutes for 10k artists)

### Admin Interface
- [ ] "Refresh Artist Ranking" action appears on artist show page
- [ ] "Refresh All Artists Rankings" action appears on artists index page
- [ ] Single artist action enqueues job and shows success message
- [ ] All artists action enqueues job and shows success message
- [ ] Actions prevent multi-select when not supported
- [ ] Actions handle missing configuration gracefully

### Public UI
- [ ] "Artists" menu item appears in music navigation
- [ ] `/artists` route works on music domain (always uses default primary album/song configs)
- [ ] Artists index page displays ranked artists in rank order
- [ ] Page shows rank, name, score, primary image, categories
- [ ] Pagination works (100 artists per page)
- [ ] Artist names link to artist show pages
- [ ] Artist show page displays rank badge if ranked
- [ ] Ranking badge shows rank number and total artists

### Edge Cases
- [ ] Handles artists with no albums or songs (zero score, not ranked)
- [ ] Handles artists with only albums (no songs)
- [ ] Handles artists with only songs (no albums)
- [ ] Handles missing primary album or song ranking configurations
- [ ] Handles ties in scores (stable sort by artist ID)
- [ ] Updates rankings when album/song rankings change
- [ ] Removes artist from rankings if all content becomes unranked

### Performance
- [ ] Calculator uses efficient queries (avoid N+1)
- [ ] Bulk upsert for ranked_items (not individual inserts)
- [ ] Index page queries are optimized with includes
- [ ] Page loads in < 1 second with 100 artists
- [ ] Full recalculation completes in < 5 minutes

## Design Decisions

### Why Use Polymorphic RankedItem Pattern?

**Decision**: Use the established `RankedItem` polymorphic pattern with `RankingConfiguration` for artist rankings.

**Rationale**:
1. **Consistency** - Matches the established pattern used for albums, songs, books, movies, and games
2. **Flexibility** - Supports multiple ranking configurations (all-time, by decade, by genre, user-specific)
3. **History** - Can preserve old rankings when algorithms change
4. **Personalization** - Each user can have custom artist rankings in the future
5. **Normalization** - Separates ranking data from core artist data
6. **Extensibility** - Easy to add new ranking types without schema changes

**Benefits**:
- Architectural consistency is critical for maintainability
- Future features (user rankings, historical rankings, genre-specific rankings) will work seamlessly
- Pattern is already well-established and understood in the codebase
- Enables rich ranking features without model bloat

### Why Aggregate from Album/Song Rankings Instead of List-Based?

**Decision**: Calculate artist rankings by summing scores from their albums and songs, rather than using a list-based approach.

**Rationale**:
1. **No canonical artist lists** - Unlike albums/songs, there are no authoritative "greatest artists" lists to aggregate
2. **Quality proxy** - An artist's total output quality (albums + songs) is a fair measure of greatness
3. **Automatic updates** - Artist rankings update automatically when album/song rankings change
4. **Objective basis** - Based on concrete data (ranked albums/songs) rather than subjective lists
5. **Comprehensive view** - Accounts for both album-oriented and singles-oriented artists

**Alternative considered**: Scrape "greatest artists" lists from external sources
- **Rejected because**: Limited authoritative sources, data quality concerns, manual curation overhead

### Why Recalculate All Artists for Single Artist Update?

**Decision**: When refreshing a single artist's ranking, recalculate all artists.

**Rationale**:
1. **Rankings are relative** - Artist rank depends on all other artists' scores
2. **Ensures consistency** - One artist's score changing could shift many ranks
3. **Simplicity** - One calculation path for both single and bulk operations
4. **Performance acceptable** - Calculation completes in < 5 minutes for 10k artists

**Alternative considered**: Only recalculate the specific artist
- **Rejected because**: Rank number would be stale, inconsistent with other artists

### Why Sum Album + Song Scores (Not Average)?

**Decision**: Total artist score is the sum of all album scores plus all song scores.

**Rationale**:
1. **Rewards prolific artists** - Artists with more acclaimed work rank higher
2. **Fair to different artist types** - Singles artists can compete via song scores
3. **Intuitive** - More acclaimed content = higher rank
4. **Matches user expectation** - Beatles (many albums + songs) should rank higher than one-hit wonders

**Alternative considered**: Average scores
- **Rejected because**: Penalizes artists with large catalogs, favors one-hit wonders

### Why Background Jobs for All Calculations?

**Decision**: All ranking calculations happen asynchronously via Sidekiq jobs.

**Rationale**:
1. **Long-running process** - 10k artists with complex queries take minutes
2. **Avoid timeouts** - Web requests would timeout before completion
3. **Admin UX** - Admin can continue working while calculation runs
4. **Matches pattern** - Consistent with album/song ranking jobs
5. **Error handling** - Job retry mechanisms handle transient failures

**Alternative considered**: Inline calculation for single artist
- **Rejected because**: Still requires recalculating all artists, would block request

### Artist Rankings Depend on Two Other Ranking Configurations

**Architectural Note**: Artist rankings have a unique dependency structure that differs from albums and songs.

**The Pattern:**
- Albums: `Music::Albums::RankingConfiguration` → aggregates from `Music::Albums::List` records via `ranked_lists`
- Songs: `Music::Songs::RankingConfiguration` → aggregates from `Music::Songs::List` records via `ranked_lists`
- **Artists**: `Music::Artists::RankingConfiguration` → aggregates from **both** album and song `ranked_items`

**The Dependency Chain:**
```
Music::Artists::RankingConfiguration (ID: 1)
  ├─ Depends on → Music::Albums::RankingConfiguration (ID: 5, primary: true)
  │   └─ Has ranked_items for albums
  │
  └─ Depends on → Music::Songs::RankingConfiguration (ID: 6, primary: true)
      └─ Has ranked_items for songs

Artist calculation:
1. Find primary album config (ID: 5)
2. Find primary song config (ID: 6)
3. Sum scores from both configs' ranked_items
4. Create ranked_items under artist config (ID: 1)
```

**Implications:**

1. **No `rc` Parameter**: Unlike albums/songs which use `/rc/:id/albums` and `/rc/:id/songs`, artist rankings use `/artists` (on the music domain) with no ranking configuration parameter. This is because we need TWO config IDs (albums and songs), not one. The calculator always fetches default primary configs.

2. **URL Structure**: The URL `/artists` (on thegreatestmusic.org) doesn't reference a specific ranking configuration ID. The artist ranking configuration exists in the database but is found via `default_primary` in the controller.

3. **No Ranked Lists**: Unlike albums/songs, artist ranking configurations have no `ranked_lists` association. The `ranked_lists` table stays empty for artist configs.

4. **Cross-Configuration Dependency**: Artist rankings are only as current as the album and song rankings. If album rankings are stale, artist rankings will be stale too.

5. **Calculation Trigger**: When album or song rankings are recalculated, artist rankings should also be recalculated to stay in sync. (Future enhancement: automatic cascade)

6. **Configuration Parameters**: The artist ranking configuration's parameters (exponent, bonus_pool_percentage) are not used since it doesn't use the weighted_list_rank gem. These parameters are inherited from the base RankingConfiguration class but ignored.

**Why This Is Acceptable:**
- It maintains the consistent `RankingConfiguration` / `RankedItem` pattern
- The aggregation logic is clear and documented
- Each domain (albums, songs, artists) has its own primary configuration
- The URL structure is simpler for users (`/artists` on the music domain)
- Follows the multi-domain architecture with DomainConstraint routing
- Future features (genre-specific artist rankings, user-specific rankings) will follow the same pattern

## Risk Assessment

### High Risk

**Performance with large artist catalogs**
- **Risk**: Artists with 50+ albums could cause slow queries
- **Mitigation**: Use batch queries with `where(id: artist.albums.pluck(:id))` and proper indexes
- **Mitigation**: Use `find_each` for processing all artists
- **Testing**: Test with artists having 100+ albums/songs

**Missing album/song ranking configurations**
- **Risk**: Calculator fails if primary configs don't exist
- **Mitigation**: Graceful handling with clear error messages
- **Mitigation**: Seed data ensures primary configs exist
- **Testing**: Test with missing configs

### Medium Risk

**Rank staleness**
- **Risk**: Artist ranks become outdated when album/song rankings update
- **Mitigation**: Trigger artist ranking recalculation when album/song rankings complete
- **Mitigation**: Admin action to manually refresh when needed
- **Future**: Consider automatic background refresh on schedule

**Ties in scores**
- **Risk**: Multiple artists with same total score
- **Mitigation**: Stable sort by artist ID as tiebreaker
- **Mitigation**: Document tie-breaking behavior
- **Testing**: Test artists with identical scores

### Low Risk

**UI integration**
- **Risk**: Inconsistent styling with albums/songs pages
- **Mitigation**: Reuse existing ranked items view patterns
- **Mitigation**: Follow established music layout conventions
- **Testing**: Manual testing of UI rendering

## Future Enhancements

### Phase 2: Artist Ranking Refinements
1. **Weighted contributions** - Weight album scores higher than song scores (configurable ratio)
2. **Role-based scoring** - Only count albums/songs where artist was primary (not featured)
3. **Time-based rankings** - Rankings by decade, era, year
4. **Genre-specific rankings** - Best rock artists, best jazz artists, etc.
5. **User personalization** - Each user can have their own artist rankings based on their preferences

### Phase 3: Advanced Features
1. **Trending artists** - Artists whose rankings are rising fastest
2. **Discovery score** - Highlight underrated artists with high quality but low mainstream recognition
3. **Collaboration graphs** - Visualize artist connections based on collaborations
4. **Artist timelines** - Show how artist's ranking evolved over their career
5. **Comparative analysis** - Compare artists side-by-side with detailed breakdowns

### Performance Optimizations
1. **Incremental updates** - Only recalculate artists whose albums/songs changed
2. **Materialized views** - Use database views for common ranking queries
3. **Caching layer** - Cache rendered ranking pages with short TTL
4. **Background refresh** - Automatic nightly recalculation of all rankings

### Data Quality
1. **Manual overrides** - Allow curators to adjust specific artist rankings
2. **Quality filters** - Exclude low-quality or spam artists from rankings
3. **Verification flags** - Mark artists as "verified" for inclusion in rankings
4. **Collaboration handling** - Decide how to attribute scores for collaborative works

## Related Documentation
- [RankingConfiguration Model](/home/shane/dev/the-greatest/docs/models/ranking_configuration.md)
- [RankedItem Model](/home/shane/dev/the-greatest/docs/models/ranked_item.md)
- [ItemRankings::Calculator Service](/home/shane/dev/the-greatest/docs/services/item_rankings/calculator.md)
- [Music::Artist Model](/home/shane/dev/the-greatest/docs/models/music/artist.md)
- [Music::Albums::Calculator](/home/shane/dev/the-greatest/docs/services/item_rankings/music/albums/calculator.md)
- [Music::Songs::Calculator](/home/shane/dev/the-greatest/docs/services/item_rankings/music/songs/calculator.md)

---

## Implementation Notes

### Approach Taken

The implementation followed the established `RankingConfiguration` / `RankedItem` pattern used throughout the codebase for albums, songs, books, movies, and games. The key difference for artist rankings is that they aggregate scores from TWO other ranking configurations (albums and songs) rather than using list-based ranking.

**Implementation Flow:**
1. Created STI model `Music::Artists::RankingConfiguration` extending base `RankingConfiguration`
2. Implemented aggregation calculator that sums album + song scores for each artist
3. Created background jobs for single artist and bulk recalculation
4. Built Avo admin actions for triggering ranking calculations
5. Created public-facing controller and view for browsing artist rankings
6. Updated navigation, routes, and artist show pages to display rankings
7. Wrote comprehensive test suite (17 tests total)

### Key Files Created/Changed

**Created Files:**
- `app/models/music/artists/ranking_configuration.rb` - STI model extending RankingConfiguration
- `app/lib/item_rankings/music/artists/calculator.rb` - Core aggregation service (250 lines)
- `app/sidekiq/music/calculate_artist_ranking_job.rb` - Single artist recalculation job
- `app/sidekiq/music/calculate_all_artists_rankings_job.rb` - Bulk recalculation job
- `app/avo/resources/music_artists_ranking_configuration.rb` - Avo admin resource
- `app/avo/actions/music/refresh_artist_ranking.rb` - Single artist Avo action
- `app/avo/actions/music/refresh_all_artists_rankings.rb` - Bulk recalculation Avo action
- `app/controllers/music/artists/ranked_items_controller.rb` - Public rankings index controller
- `app/views/music/artists/ranked_items/index.html.erb` - Artist rankings page with SEO
- `test/lib/item_rankings/music/artists/calculator_test.rb` - 12 calculator tests
- `test/sidekiq/music/calculate_artist_ranking_job_test.rb` - 2 job tests
- `test/sidekiq/music/calculate_all_artists_rankings_job_test.rb` - 1 job test
- `test/controllers/music/artists/ranked_items_controller_test.rb` - 3 controller tests
- `test/fixtures/ranking_configurations.yml` - Added music_artists_global fixture

**Modified Files:**
- `app/models/music/artist.rb` - Added `has_many :ranked_items, as: :item` association
- `app/models/ranking_configuration.rb` - Added artist calculator case to factory method
- `config/routes.rb` - Added `/artists` and `/artists/page/:page` routes (outside rc scope)
- `app/views/music/artists/show.html.erb` - Added rank badge display for ranked artists
- `app/views/layouts/music/application.html.erb` - Added "Artists" navigation link
- `app/views/music/default/index.html.erb` - Refactored hero section (smaller), added "Top Artists" button
- `app/avo/resources/music_artist.rb` - Registered ranking actions

### Challenges Encountered

**1. Test Fixture Issues**
- **Problem**: Tests referenced non-existent `comfortably_numb` song fixture
- **Solution**: Changed tests to use existing `time` fixture instead
- **Location**: `test/lib/item_rankings/music/artists/calculator_test.rb:139`

**2. Duplicate Ranked Items Validation Errors**
- **Problem**: Tests failed with "Item can only be ranked once per ranking configuration" error
- **Solution**: Added cleanup in test setup to destroy existing ranked items before creating new ones
- **Code**: `@album_config.ranked_items.destroy_all` and `@song_config.ranked_items.destroy_all`

**3. Protected Method Call Error**
- **Problem**: NoMethodError for protected `call` method in calculator
- **Solution**: Made `call` method public since it's invoked by `RankingConfiguration#calculate_rankings`
- **Learning**: Calculator services need public `call` method to work with the base ranking configuration

**4. Namespace Issues in Tests**
- **Problem**: `NameError: uninitialized constant ItemRankings::Music::Artist`
- **Solution**: Used full namespace `::Music::Artist`, `::Music::Albums::RankingConfiguration` in test stubs
- **Learning**: Be explicit with namespaces when stubbing in nested modules

**5. Avo Action Visibility Syntax**
- **Problem**: `ArgumentError: unknown keyword: :show_on` when using `show_on:` parameter in resource
- **Solution**: Removed `show_on:` parameters from resource and instead added `self.visible = -> { view.show? }` and `self.visible = -> { view.index? }` inside action classes
- **Learning**: Avo 3.x pattern is to control visibility in the action class itself, not the resource registration

**6. Standalone Action Not Working**
- **Problem**: "Refresh All Artists Rankings" action required record selection instead of running immediately
- **Solution**: Added `self.standalone = true` to the action class
- **Learning**: Bulk actions that don't operate on specific records need standalone flag

### Deviations from Plan

**No Major Deviations**: The implementation followed the detailed plan in this document very closely. Minor adjustments:

1. **Route Structure**: As planned, artist rankings route (`/artists`) was placed OUTSIDE the `rc` scope since it aggregates from two configs. This matches the documented approach.

2. **SEO Implementation**: Added page title and meta description following codebase patterns discovered via `codebase-pattern-finder` agent.

3. **Homepage Refactor**: User requested making the hero section smaller (from `min-h-[60vh]` to `py-16`) and adding "Top Artists" button - this was not in original plan but was a natural UX improvement.

4. **Path-based Pagination**: Added `/artists/page/:page` route (instead of query parameters) to match albums/songs pattern and enable caching.

### Code Examples

**Aggregation Calculator Core Logic:**
```ruby
def calculate_artist_score(artist, album_config, song_config)
  album_scores = RankedItem
    .where(item_type: "Music::Album", item_id: artist.albums.pluck(:id))
    .where(ranking_configuration_id: album_config.id)
    .sum(:score)

  song_scores = RankedItem
    .where(item_type: "Music::Song", item_id: artist.songs.pluck(:id))
    .where(ranking_configuration_id: song_config.id)
    .sum(:score)

  album_scores + song_scores
end
```

**Bulk Upsert for Performance:**
```ruby
RankedItem.upsert_all(
  ranked_items_data,
  unique_by: [:item_id, :item_type, :ranking_configuration_id],
  update_only: [:rank, :score]
)
```

**Avo Action with Visibility Control:**
```ruby
class Avo::Actions::Music::RefreshAllArtistsRankings < Avo::BaseAction
  self.name = "Refresh All Artists Rankings"
  self.message = "This will recalculate rankings for all artists..."
  self.confirm_button_label = "Refresh All Rankings"
  self.standalone = true
  self.visible = -> { view.index? }

  def handle(query:, fields:, current_user:, resource:, **args)
    config = Music::Artists::RankingConfiguration.default_primary
    unless config
      return error "No default artist ranking configuration found."
    end
    Music::CalculateAllArtistsRankingsJob.perform_async(config.id)
    succeed "All artists ranking calculation queued."
  end
end
```

### Testing Approach

**Test Coverage (17 tests total):**

1. **Calculator Tests (12 tests)** - `test/lib/item_rankings/music/artists/calculator_test.rb`
   - Successful calculation with valid data
   - Aggregation from both album and song rankings
   - Correct rank assignment
   - Score calculation accuracy
   - Handling artists with zero scores
   - Handling artists with only albums (no songs)
   - Handling artists with only songs (no albums)
   - Missing album/song configuration handling
   - Upsert behavior (updates existing ranked items)
   - Database cleanup (removes stale ranked items)
   - Result struct validation
   - Error handling

2. **Job Tests (3 tests)**
   - `test/sidekiq/music/calculate_artist_ranking_job_test.rb` (2 tests)
     - Job execution with valid artist
     - Error handling for missing configuration
   - `test/sidekiq/music/calculate_all_artists_rankings_job_test.rb` (1 test)
     - Bulk calculation job execution

3. **Controller Tests (3 tests)** - `test/controllers/music/artists/ranked_items_controller_test.rb`
   - Index action with default global configuration
   - Path-based pagination (`/artists/page/2`)
   - Graceful handling of missing ranking configuration

**Test Fixtures:**
- Created `music_artists_global` ranking configuration fixture
- Reused existing artist, album, and song fixtures

**Testing Philosophy:**
- Focus on behavior and edge cases over implementation details
- Test both happy path and error conditions
- Verify database state changes (upserts, deletions)
- Validate business rules (zero scores excluded, rank ordering)

### Performance Considerations

**Efficient Queries:**
- Used `where(id: artist.albums.pluck(:id))` for batch fetching instead of N+1 queries
- Used `find_each` for processing all artists to avoid loading entire collection into memory
- Preloaded associations in controller with `includes(item: [:categories, :primary_image])`

**Bulk Operations:**
- Used `upsert_all` for creating/updating ranked items in single transaction
- Used `delete_all` for removing stale ranked items (no callbacks needed)

**Index Utilization:**
- Leveraged existing composite unique index on `ranked_items` table
- Used `order(:rank)` which can use index for sorted retrieval

**Expected Performance:**
- Calculator tested with ~100 artists: < 1 second
- Estimated full recalculation for 10,000 artists: < 5 minutes
- Index page load with pagination: < 1 second

### Lessons Learned

**1. Avo 3.x Action Visibility Pattern**
The pattern for controlling when Avo actions appear has changed:
- OLD (Avo 2.x): `show_on: [:show]` parameter in resource registration
- NEW (Avo 3.x): `self.visible = -> { view.show? }` in action class itself

**2. Aggregation-Based Rankings Are Different**
Artist rankings don't use the standard list-based approach. Key differences:
- No `ranked_lists` association (artists don't map to external lists)
- Calculator doesn't use `weighted_list_rank` gem
- Depends on TWO other ranking configurations instead of one
- Route is outside `rc` scope since it needs two config IDs

**3. Routes and Domain Constraints**
The multi-domain architecture uses `DomainConstraint` for routing:
- URLs are domain-relative (e.g., `/artists` on thegreatestmusic.org)
- NOT namespace-based (not `/music/artists`)
- This affects how routes are defined and how path helpers work

**4. Test Fixtures and Namespacing**
When writing tests with nested modules:
- Be explicit with `::` prefix for top-level constants
- Clear fixture data between tests to avoid validation errors
- Use existing fixtures when possible to avoid fixture bloat

**5. Public vs Protected Methods in Services**
Service classes that are invoked by other classes need public interfaces:
- `call` method must be public if called by `RankingConfiguration`
- Private methods are fine for internal logic
- Document the public API clearly

### Related PRs

- Branch: `ranked-artists`
- All changes committed and ready for review

### Documentation Updated

The following documentation files were created as part of this implementation:
- `docs/models/music/artists/ranking_configuration.md`
- `docs/lib/item_rankings/music/artists/calculator.md`
- `docs/sidekiq/music/calculate_artist_ranking_job.md`
- `docs/sidekiq/music/calculate_all_artists_rankings_job.md`
- `docs/controllers/music/artists/ranked_items_controller.md`
- `docs/avo/resources/music_artists_ranking_configuration.md`
- `docs/avo/actions/music/refresh_artist_ranking.md`
- `docs/avo/actions/music/refresh_all_artists_rankings.md`
- `docs/models/music/artist.md` - Updated with new `ranked_items` association
