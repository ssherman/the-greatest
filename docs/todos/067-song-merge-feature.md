# 067 - Song Merge Feature

## Status
- **Status**: Not Started
- **Priority**: Medium
- **Created**: 2025-10-31
- **Started**:
- **Completed**:
- **Developer**: AI Agent (Claude Code)

## Overview
Implement an admin-only feature to merge two Music::Song records, consolidating all associated data from a source song into a target song. This will be implemented as an Avo action that calls a service object to handle the complex multi-model data migration, following the same patterns established by the Music::Album::Merger (see todos/060-album-merge-feature.md).

## Context
As we import music data from various sources (MusicBrainz, user submissions, AI parsing), we may end up with duplicate song entries representing the same canonical song. This is particularly common when:

1. Songs are imported independently via different routes (series imports, album imports, manual imports)
2. Same song appears on multiple releases/albums with slight variations in metadata
3. Different MusicBrainz recording IDs exist for what should be the same song
4. Songs are created before better metadata becomes available

Rather than manually updating all associations, we need a safe merge operation that:

1. Preserves all data from both songs
2. Handles polymorphic associations correctly
3. Respects unique constraints (songs can share artists, categories, lists)
4. Handles complex song-specific relationships (tracks, song relationships)
5. Properly updates the search index
6. Maintains data integrity through transactions

The merge operation will reassign all meaningful associations from the source song to the target song, then delete the source song.

## Requirements

### Functional Requirements
- [ ] Create `Music::Song::Merger` service class
- [ ] Create `Avo::Actions::Music::MergeSong` action
- [ ] Support merging exactly 2 songs (validation required)
- [ ] Reassign all associations from source to target song
- [ ] Handle unique constraint violations gracefully (find_or_create pattern)
- [ ] Remove source song from OpenSearch index
- [ ] Delete source song after successful merge
- [ ] Wrap entire operation in database transaction
- [ ] Return success/error messages to admin

### Associations to Merge

Based on research of `Music::Song` model (`web-app/app/models/music/song.rb`):

#### Direct Associations (reassign to target song):

**1. tracks** - Links songs to releases/albums
   - Table: `music_tracks`
   - Foreign key: `song_id`
   - Unique constraint: `(release_id, medium_number, position)`
   - Action: Direct reassignment via `update_all`
   - Note: Multiple tracks can reference same song (different releases), so this is safe
   - Critical: This preserves the song's connection to all releases/albums

**2. song_artists** - Artists associated with this song (join table)
   - Table: `music_song_artists`
   - Unique constraint: `(song_id, artist_id)`
   - Action: **Preserve target song's artists only (Option A)**
   - **Rationale**: Merging will only occur between songs by the same artist(s), so target's artist data is correct
   - **Implementation**: Source song's `song_artists` destroyed automatically via `dependent: :destroy` when source destroyed
   - **Note**: No merge logic needed - target artists remain unchanged

**3. identifiers** - External system IDs (MusicBrainz recording IDs, ISRCs, etc.)
   - Table: `identifiers`
   - Polymorphic: `identifiable_type = 'Music::Song'`, `identifiable_id`
   - Action: Direct reassignment via `update_all`
   - Critical: Prevents future duplicates by consolidating all external IDs

**4. credits** - Artistic and technical credits
   - Table: `music_credits`
   - Polymorphic: `creditable_type = 'Music::Song'`, `creditable_id`
   - Action: **SKIP FOR NOW** - Not currently populated
   - **Note**: Credits table is not being used yet, defer merging until credits are populated
   - **Future**: When credits are populated, add direct reassignment via `update_all`

**5. ai_chats** - Historical AI conversations
   - Table: `ai_chats`
   - Polymorphic: `parent_type = 'Music::Song'`, `parent_id`
   - Action: **NOT MERGED** - Destroyed automatically with source song
   - **Rationale**: Historical AI conversations not valuable to preserve
   - **Implementation**: Destroyed via `dependent: :destroy` when source song destroyed

**6. category_items** - Genre/style categorizations
   - Table: `category_items`
   - Polymorphic: `item_type = 'Music::Song'`, `item_id`
   - Unique constraint: `(category_id, item_type, item_id)`
   - Action: Find or create for target song
   - Side effect: Triggers search index updates via callbacks

**7. external_links** - Purchase links, reviews, information
   - Table: `external_links`
   - Polymorphic: `parent_type = 'Music::Song'`, `parent_id`
   - Action: Direct reassignment via `update_all`

**8. list_items** - Appearances in user/editorial lists
   - Table: `list_items`
   - Polymorphic: `listable_type = 'Music::Song'`, `listable_id`
   - Unique constraint: `(list_id, listable_type, listable_id)`
   - Action: Find or create for target song (preserve position if possible)

**9. song_relationships** - Forward relationships (this song covers/remixes/samples another)
   - Table: `music_song_relationships`
   - Foreign key: `song_id`
   - Unique constraint: `(song_id, related_song_id, relation_type)`
   - Action: Find or create for target song
   - **Note**: Currently not populated, but merging doesn't hurt and prepares for future use
   - Example: If source song has relationship "covers song X", target gets that relationship

**10. inverse_song_relationships** - Reverse relationships (other songs that reference this song)
   - Table: `music_song_relationships`
   - Foreign key: `related_song_id`
   - Unique constraint: `(song_id, related_song_id, relation_type)`
   - Action: Direct reassignment - update `related_song_id` to target song's ID
   - **Note**: Currently not populated, but merging doesn't hurt and prepares for future use
   - Example: If "song Y covers source song", update to "song Y covers target song"

#### Ranking System:

**11. ranked_items** - Rankings in different ranking configurations
   - Table: `ranked_items`
   - Polymorphic: `item_type = 'Music::Song'`, `item_id`
   - Unique constraint: `(item_id, item_type, ranking_configuration_id)`
   - Action: **NOT MERGED** - Destroyed automatically with source song
   - Reasoning: Same as albums - source and target can't both exist in same config
   - Side Effect: Must recalculate weights and rankings for affected configurations

#### Through Associations (Automatically Updated):
- **releases** - Through tracks, automatically updated when tracks reassigned
- **albums** - Through releases, automatically updated when tracks reassigned
- **artists** - Through song_artists, automatically updated when song_artists merged
- **categories** - Through category_items, automatically updated when category_items merged
- **lists** - Through list_items, automatically updated when list_items merged

### Associations NOT to Merge

These associations are deliberately excluded from merging:

**song_artists** - Target song's artists are preserved
- **Rationale**: Songs being merged are by the same artist(s), so target's artist data is correct
- Source song's `song_artists` destroyed automatically via `dependent: :destroy`

**ai_chats** - Historical AI conversations not valuable to preserve
- Destroyed automatically via `dependent: :destroy` when source song destroyed

**credits** - Not currently populated (deferred)
- **Future**: When credits are being used, add merge logic with direct reassignment

### Non-Functional Requirements
- [ ] Process must complete in under 30 seconds (inline, no background job)
- [ ] **CRITICAL: All operations wrapped in single database transaction**
  - Transaction ensures atomicity - either all changes succeed or none do
  - Automatic rollback on any error (constraint violation, validation failure, etc.)
  - No partial merges - prevents data inconsistency
  - Source song remains untouched if merge fails
- [ ] Graceful handling of constraint violations
- [ ] Comprehensive error messages
- [ ] Logging of all reassignment operations
- [ ] Preserve audit trail (consider logging merge operation)

### Post-Merge Background Jobs

After the merge transaction completes, we need to recalculate rankings for any affected `RankingConfiguration` records:

**Affected Configurations**: Any configuration where either source or target song has `ranked_items`

**Job 1: Recalculate List Weights**
- Job: `BulkCalculateWeightsJob`
- Location: `web-app/app/sidekiq/bulk_calculate_weights_job.rb`
- Timing: Enqueue immediately after merge
- Purpose: Recalculate weights for all `ranked_lists` in the configuration
- Usage: `BulkCalculateWeightsJob.perform_async(ranking_configuration_id)`

**Job 2: Recalculate Rankings**
- Job: `CalculateRankingsJob`
- Location: `web-app/app/sidekiq/calculate_rankings_job.rb`
- Timing: Schedule 5 minutes after merge (allows weight job to complete)
- Purpose: Recalculate rank/score for all `ranked_items` in the configuration
- Usage: `CalculateRankingsJob.perform_in(5.minutes, ranking_configuration_id)`

**Sequencing**: Weights must be calculated before rankings, hence the 5-minute delay.

## Technical Approach

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ Avo Admin Interface - Song Show Page (Target Song)         │
│ ┌─────────────────────────────────────────────────────────┐ │
│ │ Admin viewing Song #456 (the "good" one)                │ │
│ │ Clicks "Merge Another Song Into This One" action       │ │
│ └────────────────────────┬────────────────────────────────┘ │
└──────────────────────────┼──────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│ Modal with Input Fields                                     │
│ ┌─────────────────────────────────────────────────────────┐ │
│ │ Source Song ID: [____123____]                           │ │
│ │ ☑ I understand this action cannot be undone            │ │
│ │                                    [Merge Song Button]  │ │
│ └────────────────────────┬────────────────────────────────┘ │
└──────────────────────────┼──────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│ Avo::Actions::Music::MergeSong                              │
│ ┌─────────────────────────────────────────────────────────┐ │
│ │ 1. Validate source song ID provided                     │ │
│ │ 2. Validate confirmation checked                        │ │
│ │ 3. Find source song by ID                               │ │
│ │ 4. Prevent self-merge                                   │ │
│ │ 5. Call Music::Song::Merger.call(source, target)        │ │
│ │ 6. Return success/error message                         │ │
│ └────────────────────────┬────────────────────────────────┘ │
└──────────────────────────┼──────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│ Music::Song::Merger (Service)                               │
│ ┌─────────────────────────────────────────────────────────┐ │
│ │ ╔═══════════════════════════════════════════════════╗   │ │
│ │ ║ ActiveRecord::Base.transaction do                 ║   │ │
│ │ ║ (ALL-OR-NOTHING: Any error rolls back everything)║   │ │
│ │ ╚═══════════════════════════════════════════════════╝   │ │
│ │   1. collect_affected_ranking_configurations            │ │
│ │   2. merge_tracks (direct reassignment)                 │ │
│ │   3. merge_identifiers (direct reassignment)            │ │
│ │   4. merge_category_items (find_or_create)              │ │
│ │   5. merge_external_links (direct reassignment)         │ │
│ │   6. merge_list_items (find_or_create with position)    │ │
│ │   7. merge_song_relationships (find_or_create)          │ │
│ │   8. merge_inverse_song_relationships (update FK)       │ │
│ │   9. target_song.touch (triggers reindex via concern)   │ │
│ │   10. destroy_source_song (triggers unindex via concern)│ │
│ │                                                          │ │
│ │ # NOT merged (automatic destruction):                   │ │
│ │   - song_artists (target preserved)                     │ │
│ │   - credits (not populated)                             │ │
│ │   - ai_chats (not valuable)                             │ │
│ │ ╔═══════════════════════════════════════════════════╗   │ │
│ │ ║ end # Transaction commits - all changes persisted║   │ │
│ │ ╚═══════════════════════════════════════════════════╝   │ │
│ │                                                          │ │
│ │ # After transaction commits:                            │ │
│ │ 11. schedule_ranking_recalculation                      │ │
│ │     - BulkCalculateWeightsJob.perform_async             │ │
│ │     - CalculateRankingsJob.perform_in(5.minutes)        │ │
│ │                                                          │ │
│ │ # Search indexing automatic (SearchIndexable concern):  │ │
│ │   - Target: touch triggers after_commit indexing        │ │
│ │   - Source: destroy triggers after_commit unindexing    │ │
│ └─────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

### Service Class Structure

**Location**: `web-app/app/lib/music/song/merger.rb`

```ruby
module Music
  class Song
    class Merger
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      attr_reader :source_song, :target_song, :stats

      def self.call(source:, target:)
        new(source: source, target: target).call
      end

      def initialize(source:, target:)
        @source_song = source
        @target_song = target
        @stats = {}
        @affected_ranking_configurations = []
      end

      def call
        # CRITICAL: Wrap entire merge in transaction for atomicity
        # If ANY step fails, ALL changes are rolled back automatically
        ActiveRecord::Base.transaction do
          collect_affected_ranking_configurations
          merge_all_associations
          destroy_source_song
        end
        # Transaction committed successfully - all changes persisted

        # After transaction commits, schedule ranking jobs
        # Note: Search indexing handled automatically by SearchIndexable concern
        # - Target song reindexed on next save via after_commit callback
        # - Source song unindexed automatically on destroy via after_commit callback
        schedule_ranking_recalculation

        Result.new(success?: true, data: target_song, errors: [])
      rescue ActiveRecord::RecordInvalid => error
        # Validation error - transaction rolled back
        Rails.logger.error "Song merge failed - validation error: #{error.message}"
        Result.new(success?: false, data: nil, errors: [error.message])
      rescue ActiveRecord::RecordNotUnique => error
        # Unique constraint violation - transaction rolled back
        Rails.logger.error "Song merge failed - constraint violation: #{error.message}"
        Result.new(success?: false, data: nil, errors: ["Constraint violation: #{error.message}"])
      rescue => error
        # Any other error - transaction rolled back
        Rails.logger.error "Song merge failed: #{error.message}"
        Rails.logger.error error.backtrace.join("\n")
        Result.new(success?: false, data: nil, errors: [error.message])
      end

      private

      def merge_all_associations
        merge_tracks
        merge_identifiers
        merge_category_items
        merge_external_links
        merge_list_items
        merge_song_relationships
        merge_inverse_song_relationships
        # Note: song_artists NOT merged - target's artists preserved
        # Note: credits NOT merged - not currently populated
        # Note: ai_chats NOT merged - not valuable to preserve

        # Trigger target song update to queue search reindex via SearchIndexable
        target_song.touch
      end

      def collect_affected_ranking_configurations
        # Find all ranking configurations that have ranked_items for either song
        source_configs = RankedItem.where(item_type: "Music::Song", item_id: source_song.id)
          .pluck(:ranking_configuration_id)
        target_configs = RankedItem.where(item_type: "Music::Song", item_id: target_song.id)
          .pluck(:ranking_configuration_id)

        @affected_ranking_configurations = (source_configs + target_configs).uniq
        Rails.logger.info "Found #{@affected_ranking_configurations.length} affected ranking configurations"
      end

      def schedule_ranking_recalculation
        @affected_ranking_configurations.each do |config_id|
          # Recalculate weights immediately
          BulkCalculateWeightsJob.perform_async(config_id)

          # Schedule ranking calculation for 5 minutes later
          CalculateRankingsJob.perform_in(5.minutes, config_id)

          Rails.logger.info "Scheduled ranking recalculation for configuration #{config_id}"
        end
      end

      # Individual merge methods using patterns from Album::Merger
      # ...
    end
  end
end
```

### Avo Action Structure

**Location**: `web-app/app/avo/actions/music/merge_song.rb`

**Workflow**: Admin is viewing the TARGET song (the one that will survive). They enter the ID of the SOURCE song (the duplicate to be deleted and merged into the current song).

```ruby
class Avo::Actions::Music::MergeSong < Avo::BaseAction
  self.name = "Merge Another Song Into This One"
  self.message = "Enter the ID of a duplicate song to merge into the current song. All data from that song will be transferred here, and the duplicate will be deleted."
  self.confirm_button_label = "Merge Song"
  self.standalone = true  # Only works on single records

  def fields
    # Simple text field for the source song ID
    field :source_song_id,
      as: :text,
      name: "Source Song ID (to be deleted)",
      help: "Enter the ID of the duplicate song that will be merged into the current song and deleted.",
      placeholder: "e.g., 123",
      required: true

    # Confirmation checkbox for safety
    field :confirm_merge,
      as: :boolean,
      name: "I understand this action cannot be undone",
      default: false,
      help: "The source song will be permanently deleted after merging"
  end

  def handle(query:, fields:, current_user:, resource:, **args)
    # Get the target song (the one being viewed - will survive)
    target_song = query.first

    # Validate we only have one target song
    if query.count > 1
      return error "This action can only be performed on a single song at a time."
    end

    # Get the source song ID from the field
    source_song_id = fields["source_song_id"]

    unless source_song_id.present?
      return error "Please enter the ID of the song to merge."
    end

    # Check confirmation
    unless fields["confirm_merge"]
      return error "Please confirm you understand this action cannot be undone."
    end

    # Find the source song
    source_song = Music::Song.find_by(id: source_song_id)

    unless source_song
      return error "Song with ID #{source_song_id} not found."
    end

    # Prevent merging with self
    if source_song.id == target_song.id
      return error "Cannot merge a song with itself. Please enter a different song ID."
    end

    # Call merger service
    result = ::Music::Song::Merger.call(source: source_song, target: target_song)

    if result.success?
      succeed "Successfully merged '#{source_song.title}' (ID: #{source_song.id}) into '#{target_song.title}'. The source song has been deleted."
    else
      error "Failed to merge songs: #{result.errors.join(", ")}"
    end
  end
end
```

**Update to `web-app/app/avo/resources/music_song.rb`**:
```ruby
class Avo::Resources::MusicSong < Avo::BaseResource
  self.model_class = ::Music::Song

  def actions
    action Avo::Actions::Music::GenerateSongDescription
    action Avo::Actions::Music::MergeSong  # Add this
  end

  # ... rest of fields ...
end
```

### Key Implementation Patterns

Based on Album::Merger patterns and song-specific requirements:

#### Pattern 1: Direct Foreign Key Reassignment (Simple Associations)

For associations without unique constraints:

```ruby
def merge_tracks
  count = source_song.tracks.update_all(song_id: target_song.id)
  @stats[:tracks] = count
  Rails.logger.info "Merged #{count} tracks"
end

def merge_identifiers
  count = source_song.identifiers.update_all(
    identifiable_id: target_song.id
  )
  @stats[:identifiers] = count
  Rails.logger.info "Merged #{count} identifiers"
end

def merge_external_links
  count = source_song.external_links.update_all(parent_id: target_song.id)
  @stats[:external_links] = count
  Rails.logger.info "Merged #{count} external links"
end
```

#### Pattern 2: Find or Create for Join Tables

For associations with unique constraints:

```ruby
def merge_category_items
  count = 0
  source_song.category_items.find_each do |category_item|
    target_song.category_items.find_or_create_by!(
      category_id: category_item.category_id
    )
    count += 1
  end
  @stats[:category_items] = count
  Rails.logger.info "Merged #{count} category items"
end

def merge_list_items
  count = 0
  source_song.list_items.find_each do |list_item|
    target_song.list_items.find_or_create_by!(
      list_id: list_item.list_id
    ) do |new_list_item|
      new_list_item.position = list_item.position
    end
    count += 1
  end
  @stats[:list_items] = count
  Rails.logger.info "Merged #{count} list items"
end
```

#### Pattern 3: Song Relationships (Forward)

Handle forward relationships (this song relates to another):

```ruby
def merge_song_relationships
  count = 0
  source_song.song_relationships.find_each do |relationship|
    target_song.song_relationships.find_or_create_by!(
      related_song_id: relationship.related_song_id,
      relation_type: relationship.relation_type
    ) do |new_relationship|
      new_relationship.source_release_id = relationship.source_release_id
    end
    count += 1
  end
  @stats[:song_relationships] = count
  Rails.logger.info "Merged #{count} song relationships"
end
```

#### Pattern 4: Inverse Song Relationships (Reverse)

Handle reverse relationships (other songs relate to this song):

```ruby
def merge_inverse_song_relationships
  # Update all relationships where source_song is the related_song
  # Change related_song_id to point to target_song instead
  count = Music::SongRelationship.where(related_song_id: source_song.id)
    .update_all(related_song_id: target_song.id)

  @stats[:inverse_song_relationships] = count
  Rails.logger.info "Merged #{count} inverse song relationships"
end
```

**Why update_all is safe here**:
- Unique constraint is on `(song_id, related_song_id, relation_type)`
- We're only updating `related_song_id`
- If conflict occurs (song X already has relationship to target), constraint violation triggers rollback
- This is acceptable - means relationship already exists, merge can retry after manual cleanup

#### Pattern 5: Search Index Update (Automatic via SearchIndexable)

```ruby
def merge_all_associations
  # ... all merge operations ...

  # Trigger target song update to queue search reindex via SearchIndexable
  # The SearchIndexable concern's after_commit callback will create SearchIndexRequest
  target_song.touch
end

def destroy_source_song
  source_song.destroy!
  Rails.logger.info "Destroyed source song"
  # Note: SearchIndexable concern automatically queues unindex_item on destroy via after_commit callback
end
```

**Why this works**:
- `Music::Song` includes `SearchIndexable` concern (line 23 in `music/song.rb`)
- `SearchIndexable` has `after_commit :queue_for_indexing, on: [:create, :update]`
- `SearchIndexable` has `after_commit :queue_for_unindexing, on: :destroy`
- Calling `target_song.touch` triggers an update, which triggers the indexing callback
- Destroying source song triggers the unindexing callback
- No manual `SearchIndexRequest.create!` needed

## Dependencies

### Gems
- No new gems required (all functionality available in Rails/ActiveRecord)

### Models
- `Music::Song` (`web-app/app/models/music/song.rb`)
- `Music::Track` (`web-app/app/models/music/track.rb`)
- `Music::SongRelationship` (`web-app/app/models/music/song_relationship.rb`)
- `Identifier` (`web-app/app/models/identifier.rb`)
- `CategoryItem` (`web-app/app/category_item.rb`)
- `ExternalLink` (`web-app/app/models/external_link.rb`)
- `ListItem` (`web-app/app/models/list_item.rb`)
- `RankedItem` (`web-app/app/models/ranked_item.rb`)
- `RankingConfiguration` (`web-app/app/models/ranking_configuration.rb`)
- `SearchIndexRequest` (`web-app/app/models/search_index_request.rb`)

**Note**: The following models are NOT used in the merger:
- `Music::SongArtist` - Target's artists preserved, not merged
- `Music::Credit` - Not currently populated, deferred
- `AiChat` - Not valuable to preserve

### Sidekiq Jobs
- `BulkCalculateWeightsJob` (`web-app/app/sidekiq/bulk_calculate_weights_job.rb`)
- `CalculateRankingsJob` (`web-app/app/sidekiq/calculate_rankings_job.rb`)

### Existing Patterns
- `Music::Album::Merger` - Reference implementation for similar merge logic
- `Categories::Merger` - Another reference for merge patterns
- `ItemRankings::Calculator` - Reference for ranking system integration
- Avo actions in `web-app/app/avo/actions/` - Reference for action structure

### External Services
- OpenSearch (search index cleanup)

## Acceptance Criteria

### Service Class
- [ ] `Music::Song::Merger.call(source:, target:)` merges all associations
- [ ] Returns structured Result object with success/failure
- [ ] **Wrapped in database transaction (rollback on error)**
  - [ ] Transaction begins before any database changes
  - [ ] On success: all changes committed atomically
  - [ ] On error: automatic rollback - both songs remain unchanged
  - [ ] No partial merges possible under any error condition
- [ ] Handles unique constraint violations gracefully (returns error Result)
- [ ] Logs detailed statistics about merged records
- [ ] Identifies all affected RankingConfiguration records
- [ ] Schedules BulkCalculateWeightsJob for each affected configuration (immediate)
- [ ] Schedules CalculateRankingsJob for each affected configuration (5 minutes delayed)
- [ ] Background jobs only scheduled AFTER transaction commits successfully
- [ ] Triggers target song update (via `touch`) to queue reindex (automatic via SearchIndexable)
- [ ] Removes source song from search index on destroy (automatic via SearchIndexable)
- [ ] Deletes source song record after successful merge

### Avo Action
- [ ] Action appears in Music::Song resource actions list
- [ ] Action works on single song only (`self.standalone = true`)
- [ ] Action name clearly indicates current song is the target: "Merge Another Song Into This One"
- [ ] Displays modal with text field for source song ID
- [ ] Displays confirmation checkbox field
- [ ] Validates source song ID is provided
- [ ] Validates confirmation checkbox is checked
- [ ] Finds source song by ID and shows clear error if not found
- [ ] Prevents merging song with itself
- [ ] Shows clear success message with both song names and source ID
- [ ] Displays detailed error messages on failure
- [ ] Action completes in under 30 seconds for typical songs

### Data Integrity
- [ ] All source tracks reassigned to target song
- [ ] Target song's artists preserved (source artists destroyed)
- [ ] All source identifiers moved to target (prevents future duplicates)
- [ ] All source categories merged (no duplicates)
- [ ] All source external links moved to target
- [ ] All source list appearances preserved
- [ ] All source song relationships (forward) merged (prepares for future use)
- [ ] All inverse relationships updated to point to target (prepares for future use)
- [ ] Source ranked_items destroyed automatically
- [ ] Rankings recalculated for affected configurations (via background jobs)
- [ ] Source song removed from database and search index (automatic)
- [ ] Target song reindexed with merged data (automatic via `touch`)
- [ ] Source credits destroyed (not currently populated)
- [ ] Source AI chats destroyed (not valuable to preserve)
- [ ] No orphaned records remain

### Edge Cases
- [ ] Handles songs by same artist (artists not merged, target preserved)
- [ ] Handles songs in same lists (no duplicate list_items)
- [ ] Handles songs in same categories (no duplicate category_items)
- [ ] Handles songs with mutual relationships (A covers B, B remixes A) - future-proofing
- [ ] Handles songs with circular relationships (A covers B covers C covers A) - future-proofing
- [ ] Handles songs with no associations
- [ ] Handles songs with hundreds of tracks (appearing on many releases)
- [ ] Handles songs with no ranked_items (no jobs scheduled)
- [ ] Handles songs in multiple ranking configurations (all recalculated)
- [ ] Handles inverse relationship conflicts gracefully - future-proofing

### Transaction Rollback Scenarios
- [ ] **Validation failure**: Source song invalid state - transaction rolls back, error returned
- [ ] **Constraint violation**: Unexpected unique constraint hit - transaction rolls back, no changes
- [ ] **Database error**: Connection lost mid-merge - transaction rolls back automatically
- [ ] **Source song deletion fails**: All reassignments rolled back, songs unchanged
- [ ] **Inverse relationship conflict**: Song X -> Source, Song X -> Target already exists - rollback
- [ ] **After rollback**: Both songs remain in original state, can retry merge
- [ ] **No background jobs scheduled** if transaction fails (jobs only queued after commit)

## Design Decisions

### Why Text Input for Song ID Instead of Searchable Dropdown?
- Admin already knows the duplicate's ID from browsing the site
- Simpler implementation (no search configuration needed)
- Faster workflow - just paste the ID
- Clear mental model: viewing target, entering source
- No ambiguity about which song is which (current page = target, entered ID = source)
- Matches Album merger pattern for consistency

### Why Service Object Pattern?
- Complex multi-model operation
- Reusable logic outside Avo context
- Easier to test in isolation
- Clear Result object for success/failure handling
- Matches existing patterns (`Music::Album::Merger`, `Categories::Merger`)

### Why Inline (No Background Job)?
- Typical song merge completes in seconds
- Admin needs immediate feedback
- Transaction semantics work better inline
- Simpler error handling and rollback
- Consistent with Album merger approach

### Why NOT Merge Song Artists (Like Albums)?
**Decision**: Preserve target song's artists only, do not merge.

**Rationale**: Song merging will only occur between songs by the same artist(s). If songs have different artists, they should not be merged as they represent different recordings. The target song's artist data is correct for the canonical version.

**Implementation**: Source song's `song_artists` destroyed automatically via `dependent: :destroy` when source song destroyed. No merge logic needed.

### Why NOT Merge AI Chats or Credits?
**AI Chats**: Not valuable to preserve - historical conversations don't add value to merged song. Destroyed automatically via `dependent: :destroy`.

**Credits**: Not currently populated in the database. Deferred until credits are being actively used. When implemented in the future, should use direct reassignment via `update_all`.

### Why Merge Song Relationships (Even Though Not Currently Populated)?
**Decision**: Include merge logic for song relationships even though the table is not currently populated.

**Rationale**:
- No harm in including the merge logic - it's defensive programming
- Prepares for future use when relationships are populated
- Follows DRY principle - won't need to update merger later
- Transaction safety ensures any issues trigger rollback

**Implementation**:
- Forward relationships: find_or_create to avoid duplicates
- Inverse relationships: update_all since we're changing the pointer
- Constraint violations trigger rollback - requires manual resolution before retry

### Why Direct Reassignment for Most Associations?
- Faster than find-or-create
- No unique constraints to violate
- Simpler code
- Lower database overhead
- Matches Album merger patterns

### Why Database Transaction is Critical?
- **Prevents partial merges**: Without transaction, failure halfway through leaves songs in inconsistent state
- **Automatic rollback**: Any error (validation, constraint violation, DB error) automatically undoes all changes
- **Data integrity**: Ensures source song is either fully merged and deleted, or remains completely unchanged
- **No manual cleanup needed**: Rails handles rollback automatically - no orphaned records
- **Safe to retry**: Failed merge leaves both songs in original state - admin can fix issue and retry
- **Example failure scenarios**:
  - If `destroy_source_song` fails, all reassignments are rolled back
  - If unique constraint violated on inverse_song_relationships, nothing is changed
  - If database connection lost mid-merge, all changes are rolled back

### Why Update Inverse Relationships?
Songs have bidirectional relationships (covers, remixes, samples, alternates). When merging:
- Source song has forward relationships: "Source covers Song X" → "Target covers Song X"
- Other songs have relationships to source: "Song Y covers Source" → "Song Y covers Target"

Must update both directions to maintain referential integrity.

## Risk Assessment

### High Risk - MITIGATED BY TRANSACTION

- **❌ Data loss if merge fails mid-operation**
  - ✅ **MITIGATED**: Transaction wraps entire operation - automatic rollback on any error
  - ✅ **RESULT**: No partial merges possible - songs remain in original state on failure
  - Testing: Test rollback scenarios (simulate DB errors, constraint violations)

- **❌ Unique constraint violations causing data corruption**
  - ✅ **MITIGATED**: Use find_or_create for constrained tables + transaction rollback
  - ✅ **RESULT**: Constraint violation triggers rollback - no changes persist
  - Testing: Test songs with overlapping associations (same artists, categories, lists, relationships)

- **❌ Circular or mutual song relationships causing infinite loops or conflicts**
  - ✅ **MITIGATED**: find_or_create prevents duplicates, transaction prevents partial updates
  - ✅ **RESULT**: Relationships merged correctly, constraint violations cause safe rollback
  - Testing: Test mutual relationships (A covers B, B remixes A) and circular (A->B->C->A)

### Medium Risk

- **Performance with songs having hundreds of tracks (e.g., compilation appearances)**
  - Mitigation: Use update_all where possible
  - Mitigation: Use find_each for batch processing
  - Testing: Test with large fixture songs

- **Inverse relationship conflicts**
  - Mitigation: Let constraint violations trigger rollback
  - Mitigation: Clear error messages guide admin to manual resolution
  - Testing: Test songs where other songs relate to both source and target

- **Position conflicts in song_artists and list_items**
  - Mitigation: Only set position when creating new records (not updating)
  - Mitigation: Position from source preserved if no conflict
  - Testing: Test merging songs with same artist at different positions

### Low Risk

- **Search index not updated**
  - Mitigation: Automatic via SearchIndexable concern (target: `touch` triggers reindex, source: destroy triggers unindex)
  - Testing: Verify SearchIndexable callbacks fire correctly

- **Ranking jobs not scheduled**
  - Mitigation: Collect affected configs before destroying source
  - Testing: Verify jobs scheduled with correct arguments

---

## Implementation Notes

*This section will be filled out during/after implementation*

### Approach Taken

### Files Created

### Files Modified

### Challenges Encountered

### Deviations from Plan

### Code Examples

### Testing Approach

### Performance Considerations

### Future Improvements

### Lessons Learned

### Related PRs

### Documentation Updated
- [ ] Create `docs/lib/music/song/merger.md` - Complete service documentation
- [ ] Update `docs/models/music/song.md` - Add merge section
- [ ] No Avo action documentation needed (per testing guide - manually test admin UI)

---

## Related Documentation
- [Music::Album::Merger Service](../lib/music/album/merger.md) - Reference implementation
- [Music::Album Merge Todo](060-album-merge-feature.md) - Similar completed task
- [Music::Song Model](../models/music/song.md) - Model documentation with SearchIndexable
- [SearchIndexable Concern](../concerns/search_indexable.md) - Automatic indexing behavior (no manual SearchIndexRequest needed)
- [SearchIndexRequest Model](../models/search_index_request.md) - Search queue documentation
- [Testing Guide](../testing.md) - Testing standards

**Key Difference from Album Merger**: Songs use automatic search indexing via SearchIndexable concern. Target song reindexing triggered by `touch`, source unindexing triggered by `destroy`. No manual SearchIndexRequest creation needed.
