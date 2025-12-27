# 060 - Album Merge Feature

## Status
- **Status**: Completed
- **Priority**: Medium
- **Created**: 2025-10-23
- **Started**: 2025-10-24
- **Completed**: 2025-10-24
- **Developer**: AI Agent (Claude Code)

## Overview
Implement an admin-only feature to merge two Music::Album records, consolidating all associated data from the source album into the target album. This will be implemented as an Avo action that calls a service object to handle the complex multi-model data migration.

## Context
As we import music data from various sources (MusicBrainz, user submissions, AI parsing), we may end up with duplicate album entries representing the same canonical album. Rather than manually updating all associations, we need a safe merge operation that:

1. Preserves all data from both albums
2. Handles polymorphic associations correctly
3. Respects unique constraints (albums can share artists, categories, lists)
4. Properly updates the search index
5. Maintains data integrity through transactions

The merge operation will reassign all meaningful associations from the source album to the target album, then delete the source album.

## Requirements

### Functional Requirements
- [ ] Create `Music::Album::Merger` service class
- [ ] Create `Avo::Actions::Music::MergeAlbum` action
- [ ] Support merging exactly 2 albums (validation required)
- [ ] Reassign all associations from source to target album
- [ ] Handle unique constraint violations gracefully (find_or_create pattern)
- [ ] Remove source album from OpenSearch index
- [ ] Delete source album after successful merge
- [ ] Wrap entire operation in database transaction
- [ ] Return success/error messages to admin

### Associations to Merge

Based on research of `Music::Album` model (`web-app/app/models/music/album.rb`):

**Direct Associations** (reassign to target album):
1. **album_artists** - Artists associated with this album (join table)
   - Table: `music_album_artists`
   - Unique constraint: `(album_id, artist_id)`
   - Action: Find or create for target album

2. **releases** - All commercial releases (CD, vinyl, digital, etc.)
   - Table: `music_releases`
   - Foreign key: `album_id`
   - Action: Direct reassignment (releases have their own associations that will follow)
   - Note: Releases have dependencies: tracks, songs (through), credits, identifiers, images, external_links

3. **credits** - Artistic and technical credits
   - Table: `music_credits`
   - Polymorphic: `creditable_type = 'Music::Album'`, `creditable_id`
   - **⚠️ SKIP FOR NOW**: Credits not currently populated - defer migration until credits are being used
   - **Future**: When implemented, use direct reassignment like other polymorphic associations

4. **identifiers** - External system IDs (MusicBrainz, Discogs, AllMusic, etc.)
   - Table: `identifiers`
   - Polymorphic: `identifiable_type = 'Music::Album'`, `identifiable_id`
   - Action: Direct reassignment (crucial for preventing future duplicates)

5. **category_items** - Genre/style categorizations
   - Table: `category_items`
   - Polymorphic: `item_type = 'Music::Album'`, `item_id`
   - Unique constraint: `(category_id, item_type, item_id)`
   - Action: Find or create for target album
   - Side effect: Triggers search index updates via callbacks

6. **images** - Cover art and other images
   - Table: `images`
   - Polymorphic: `parent_type = 'Music::Album'`, `parent_id`
   - Action: Direct reassignment
   - Special handling: Ensure only one `primary: true` image per album

7. **external_links** - Purchase links, reviews, information
   - Table: `external_links`
   - Polymorphic: `parent_type = 'Music::Album'`, `parent_id`
   - Action: Direct reassignment

8. **list_items** - Appearances in user/editorial lists
   - Table: `list_items`
   - Polymorphic: `listable_type = 'Music::Album'`, `listable_id`
   - Unique constraint: `(list_id, listable_type, listable_id)`
   - Action: Find or create for target album (preserve position if possible)

9. **ranked_items** - Rankings in different ranking configurations
   - Table: `ranked_items`
   - Polymorphic: `item_type = 'Music::Album'`, `item_id`
   - Unique constraint: `(item_id, item_type, ranking_configuration_id)`
   - Action: Direct reassignment (update `item_id` to target album)
   - Note: No duplicates possible due to unique constraint - same album can't be ranked twice in same configuration
   - Side Effect: Must recalculate weights and rankings for affected configurations (see Post-Merge Jobs section)

**Associations to Ignore**:
- **ai_chats** - Historical AI conversations (not valuable to preserve)

**Associations to Defer (Not Currently Populated)**:
- **credits** - Will be added to merger when credits are being actively populated

### Non-Functional Requirements
- [ ] Process must complete in under 30 seconds (inline, no background job)
- [ ] **CRITICAL: All operations wrapped in single database transaction**
  - Transaction ensures atomicity - either all changes succeed or none do
  - Automatic rollback on any error (constraint violation, validation failure, etc.)
  - No partial merges - prevents data inconsistency
  - Source album remains untouched if merge fails
- [ ] Graceful handling of constraint violations
- [ ] Comprehensive error messages
- [ ] Logging of all reassignment operations
- [ ] Preserve audit trail (consider logging merge operation)

### Post-Merge Background Jobs

After the merge transaction completes, we need to recalculate rankings for any affected `RankingConfiguration` records:

**Affected Configurations**: Any configuration where either source or target album has `ranked_items`

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
│ Avo Admin Interface - Album Show Page (Target Album)       │
│ ┌─────────────────────────────────────────────────────────┐ │
│ │ Admin viewing Album #456 (the "good" one)               │ │
│ │ Clicks "Merge Another Album Into This One" action      │ │
│ └────────────────────────┬────────────────────────────────┘ │
└──────────────────────────┼──────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│ Modal with Input Fields                                     │
│ ┌─────────────────────────────────────────────────────────┐ │
│ │ Source Album ID: [____123____]                          │ │
│ │ ☑ I understand this action cannot be undone            │ │
│ │                                    [Merge Album Button] │ │
│ └────────────────────────┬────────────────────────────────┘ │
└──────────────────────────┼──────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│ Avo::Actions::Music::MergeAlbum                             │
│ ┌─────────────────────────────────────────────────────────┐ │
│ │ 1. Validate source album ID provided                    │ │
│ │ 2. Validate confirmation checked                        │ │
│ │ 3. Find source album by ID                              │ │
│ │ 4. Prevent self-merge                                   │ │
│ │ 5. Call Music::Album::Merger.call(source, target)       │ │
│ │ 6. Return success/error message                         │ │
│ └────────────────────────┬────────────────────────────────┘ │
└──────────────────────────┼──────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│ Music::Album::Merger (Service)                              │
│ ┌─────────────────────────────────────────────────────────┐ │
│ │ ╔═══════════════════════════════════════════════════╗   │ │
│ │ ║ ActiveRecord::Base.transaction do                 ║   │ │
│ │ ║ (ALL-OR-NOTHING: Any error rolls back everything)║   │ │
│ │ ╚═══════════════════════════════════════════════════╝   │ │
│ │   1. merge_album_artists                                │ │
│ │   2. merge_releases (direct reassignment)               │ │
│ │   3. merge_identifiers (direct reassignment)            │ │
│ │   4. merge_category_items (find_or_create)              │ │
│ │   5. merge_images (with primary handling)               │ │
│ │   6. merge_external_links (direct reassignment)         │ │
│ │   7. merge_list_items (find_or_create)                  │ │
│ │   8. merge_ranked_items (direct reassignment)           │ │
│ │   9. collect_affected_ranking_configurations            │ │
│ │   10. update_search_index (remove source)               │ │
│ │   11. destroy_source_album                              │ │
│ │ ╔═══════════════════════════════════════════════════╗   │ │
│ │ ║ end # Transaction commits - all changes persisted║   │ │
│ │ ╚═══════════════════════════════════════════════════╝   │ │
│ │ # Note: credits skipped - not currently populated       │ │
│ │                                                          │ │
│ │ # After transaction commits successfully:               │ │
│ │ 13. schedule_ranking_recalculation                      │ │
│ │     - BulkCalculateWeightsJob.perform_async             │ │
│ │     - CalculateRankingsJob.perform_in(5.minutes)        │ │
│ └─────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

### Service Class Structure

**Location**: `web-app/app/lib/music/album/merger.rb`

```ruby
module Music
  class Album
    class Merger
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      attr_reader :source_album, :target_album, :stats

      def self.call(source:, target:)
        new(source: source, target: target).call
      end

      def initialize(source:, target:)
        @source_album = source
        @target_album = target
        @stats = {}
        @affected_ranking_configurations = []
      end

      def call
        # CRITICAL: Wrap entire merge in transaction for atomicity
        # If ANY step fails, ALL changes are rolled back automatically
        ActiveRecord::Base.transaction do
          merge_all_associations
          collect_affected_ranking_configurations
          unindex_source_album
          destroy_source_album
        end
        # Transaction committed successfully - all changes persisted

        # After transaction commits, schedule ranking recalculation
        # These jobs are scheduled AFTER commit to ensure data consistency
        schedule_ranking_recalculation

        Result.new(success?: true, data: target_album, errors: [])
      rescue ActiveRecord::RecordInvalid => error
        # Validation error - transaction rolled back
        Rails.logger.error "Album merge failed - validation error: #{error.message}"
        Result.new(success?: false, data: nil, errors: [error.message])
      rescue ActiveRecord::RecordNotUnique => error
        # Unique constraint violation - transaction rolled back
        Rails.logger.error "Album merge failed - constraint violation: #{error.message}"
        Result.new(success?: false, data: nil, errors: ["Constraint violation: #{error.message}"])
      rescue => error
        # Any other error - transaction rolled back
        Rails.logger.error "Album merge failed: #{error.message}"
        Rails.logger.error error.backtrace.join("\n")
        Result.new(success?: false, data: nil, errors: [error.message])
      end

      private

      def merge_all_associations
        merge_album_artists
        merge_releases
        # merge_credits - SKIP: not currently populated
        merge_identifiers
        merge_category_items
        merge_images
        merge_external_links
        merge_list_items
        merge_ranked_items
      end

      def collect_affected_ranking_configurations
        # Find all ranking configurations that have ranked_items for either album
        source_configs = RankedItem.where(item_type: 'Music::Album', item_id: source_album.id)
                                    .pluck(:ranking_configuration_id)
        target_configs = RankedItem.where(item_type: 'Music::Album', item_id: target_album.id)
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

      # Individual merge methods using patterns from Categories::Merger
      # ...
    end
  end
end
```

### Avo Action Structure

**Location**: `web-app/app/avo/actions/music/merge_album.rb`

**Workflow**: Admin is viewing the TARGET album (the one that will survive). They enter the ID of the SOURCE album (the duplicate to be deleted and merged into the current album).

```ruby
class Avo::Actions::Music::MergeAlbum < Avo::BaseAction
  self.name = "Merge Another Album Into This One"
  self.message = "Enter the ID of a duplicate album to merge into the current album. All data from that album will be transferred here, and the duplicate will be deleted."
  self.confirm_button_label = "Merge Album"
  self.standalone = true  # Only works on single records

  # Simple text field for the source album ID
  field :source_album_id,
        as: :text,
        name: "Source Album ID (to be deleted)",
        help: "Enter the ID of the duplicate album that will be merged into the current album and deleted.",
        placeholder: "e.g., 123",
        required: true

  # Confirmation checkbox for safety
  field :confirm_merge,
        as: :boolean,
        name: "I understand this action cannot be undone",
        default: false,
        help: "The source album will be permanently deleted after merging"

  def handle(query:, fields:, current_user:, resource:, **args)
    # Get the target album (the one being viewed - will survive)
    target_album = query.first

    # Validate we only have one target album
    if query.count > 1
      return error "This action can only be performed on a single album at a time."
    end

    # Get the source album ID from the field (accessed via string key)
    source_album_id = fields["source_album_id"]

    unless source_album_id.present?
      return error "Please enter the ID of the album to merge."
    end

    # Check confirmation
    unless fields["confirm_merge"]
      return error "Please confirm you understand this action cannot be undone."
    end

    # Find the source album
    source_album = Music::Album.find_by(id: source_album_id)

    unless source_album
      return error "Album with ID #{source_album_id} not found."
    end

    # Prevent merging with self
    if source_album.id == target_album.id
      return error "Cannot merge an album with itself. Please enter a different album ID."
    end

    # Call merger service
    result = ::Music::Album::Merger.call(source: source_album, target: target_album)

    if result.success?
      succeed "Successfully merged '#{source_album.title}' (ID: #{source_album.id}) into '#{target_album.title}'. The source album has been deleted."
    else
      error "Failed to merge albums: #{result.errors.join(', ')}"
    end
  end
end
```

**Update to `web-app/app/avo/resources/music_album.rb`**:
```ruby
class Avo::Resources::MusicAlbum < Avo::BaseResource
  self.model_class = ::Music::Album

  def actions
    action Avo::Actions::Music::GenerateAlbumDescription
    action Avo::Actions::Music::MergeAlbum  # Add this
  end

  # ... rest of fields ...
end
```

### Key Implementation Patterns

Based on research findings:

#### Pattern 1: Direct Foreign Key Reassignment
For associations without unique constraints (identifiers, images, external_links):

```ruby
def merge_identifiers
  count = source_album.identifiers.update_all(
    identifiable_id: target_album.id
  )
  @stats[:identifiers] = count
  Rails.logger.info "Merged #{count} identifiers"
end

# Note: credits are skipped for now - not currently populated
```

#### Pattern 2: Find or Create for Join Tables
For associations with unique constraints (album_artists, category_items):

```ruby
def merge_album_artists
  count = 0
  source_album.album_artists.find_each do |album_artist|
    target_album.album_artists.find_or_create_by!(
      artist_id: album_artist.artist_id,
      position: album_artist.position
    )
    count += 1
  end
  @stats[:album_artists] = count
  Rails.logger.info "Merged #{count} album artists"
end
```

#### Pattern 3: Ranked Items Reassignment
For ranked_items - simple reassignment with post-merge recalculation:

```ruby
def merge_ranked_items
  # Simple reassignment - unique constraint prevents duplicates
  count = RankedItem.where(
    item_type: 'Music::Album',
    item_id: source_album.id
  ).update_all(item_id: target_album.id)

  @stats[:ranked_items] = count
  Rails.logger.info "Reassigned #{count} ranked items"

  # Note: Rankings will be recalculated by background jobs after merge
end
```

**Why this is simple**:
- Unique constraint `(item_id, item_type, ranking_configuration_id)` prevents duplicates
- Same album can't be ranked twice in same configuration
- No conflict resolution needed - they're guaranteed to be different configurations
- Background jobs handle recalculation of actual rank/score values

#### Pattern 4: Primary Image Handling
Ensure only one primary image:

```ruby
def merge_images
  # If target has primary image, all source images become non-primary
  # If target has no primary, keep source primary if it exists

  has_target_primary = target_album.primary_image.present?

  source_album.images.find_each do |image|
    image.update!(
      parent_id: target_album.id,
      primary: has_target_primary ? false : image.primary
    )
  end

  @stats[:images] = source_album.images.count
end
```

#### Pattern 5: OpenSearch Index Removal

```ruby
def unindex_source_album
  SearchIndexRequest.create!(
    parent: source_album,
    action: :unindex_item
  )
  # Background job will process this within 30 seconds
  # Since we're in a transaction, this will be queued after commit
end
```

#### Pattern 6: Scheduling Ranking Recalculation Jobs

```ruby
def collect_affected_ranking_configurations
  # Find all ranking configurations that have ranked_items for either album
  source_configs = RankedItem.where(item_type: 'Music::Album', item_id: source_album.id)
                              .pluck(:ranking_configuration_id)
  target_configs = RankedItem.where(item_type: 'Music::Album', item_id: target_album.id)
                              .pluck(:ranking_configuration_id)

  @affected_ranking_configurations = (source_configs + target_configs).uniq
  Rails.logger.info "Found #{@affected_ranking_configurations.length} affected ranking configurations"
end

def schedule_ranking_recalculation
  # Called AFTER transaction commits
  @affected_ranking_configurations.each do |config_id|
    # Step 1: Recalculate weights immediately
    BulkCalculateWeightsJob.perform_async(config_id)

    # Step 2: Schedule ranking calculation for 5 minutes later (allows weights to complete)
    CalculateRankingsJob.perform_in(5.minutes, config_id)

    Rails.logger.info "Scheduled ranking recalculation for configuration #{config_id}"
  end
end
```

**Why 5-minute delay**:
- Weight calculation must complete before ranking calculation
- Weights affect the ranking algorithm
- 5 minutes provides buffer for weight job to finish processing
- Using `perform_in(5.minutes, id)` schedules job for future execution

## Dependencies

### Gems
- No new gems required (all functionality available in Rails/ActiveRecord)

### Models
- `Music::Album` (`web-app/app/models/music/album.rb`)
- `Music::AlbumArtist` (`web-app/app/models/music/album_artist.rb`)
- `Music::Release` (`web-app/app/models/music/release.rb`)
- `Identifier` (`web-app/app/models/identifier.rb`)
- `CategoryItem` (`web-app/app/models/category_item.rb`)
- `Image` (`web-app/app/models/image.rb`)
- `ExternalLink` (`web-app/app/models/external_link.rb`)
- `ListItem` (`web-app/app/models/list_item.rb`)
- `RankedItem` (`web-app/app/models/ranked_item.rb`)
- `RankingConfiguration` (`web-app/app/models/ranking_configuration.rb`)
- `SearchIndexRequest` (`web-app/app/models/search_index_request.rb`)

**Note**: `Music::Credit` is not used in this implementation as credits are not currently being populated.

### Sidekiq Jobs
- `BulkCalculateWeightsJob` (`web-app/app/sidekiq/bulk_calculate_weights_job.rb`)
- `CalculateRankingsJob` (`web-app/app/sidekiq/calculate_rankings_job.rb`)

### Existing Patterns
- `Categories::Merger` - Reference implementation for similar merge logic
- `ItemRankings::Calculator` - Reference for upsert patterns
- Avo actions in `web-app/app/avo/actions/` - Reference for action structure

### External Services
- OpenSearch (search index cleanup)

## Acceptance Criteria

### Service Class
- [ ] `Music::Album::Merger.call(source:, target:)` merges all associations
- [ ] Returns structured Result object with success/failure
- [ ] **Wrapped in database transaction (rollback on error)**
  - [ ] Transaction begins before any database changes
  - [ ] On success: all changes committed atomically
  - [ ] On error: automatic rollback - both albums remain unchanged
  - [ ] No partial merges possible under any error condition
- [ ] Handles unique constraint violations gracefully (returns error Result, no exception raised to caller)
- [ ] Logs detailed statistics about merged records
- [ ] Identifies all affected RankingConfiguration records
- [ ] Schedules BulkCalculateWeightsJob for each affected configuration (immediate)
- [ ] Schedules CalculateRankingsJob for each affected configuration (5 minutes delayed)
- [ ] Background jobs only scheduled AFTER transaction commits successfully
- [ ] Removes source album from search index
- [ ] Deletes source album record after successful merge

### Avo Action
- [ ] Action appears in Music::Album resource actions list
- [ ] Action works on single album only (`self.standalone = true`)
- [ ] Action name clearly indicates current album is the target: "Merge Another Album Into This One"
- [ ] Displays modal with text field for source album ID
- [ ] Displays confirmation checkbox field
- [ ] Validates source album ID is provided
- [ ] Validates confirmation checkbox is checked
- [ ] Finds source album by ID and shows clear error if not found
- [ ] Prevents merging album with itself
- [ ] Shows clear success message with both album names and source ID
- [ ] Displays detailed error messages on failure
- [ ] Action completes in under 30 seconds for typical albums

### Data Integrity
- [ ] All source album artists appear in target album
- [ ] All source releases reassigned to target album
- [ ] All source identifiers moved to target (prevents future duplicates)
- [ ] All source categories merged (no duplicates)
- [ ] All source list appearances preserved
- [ ] All source ranked_items reassigned to target album
- [ ] Rankings recalculated for affected configurations (via background jobs)
- [ ] Only one primary image per merged album
- [ ] Source album removed from database and search index
- [ ] No orphaned records remain

### Edge Cases
- [ ] Handles albums with shared artists (no duplicate album_artists)
- [ ] Handles albums in same lists (no duplicate list_items)
- [ ] Handles albums in same categories (no duplicate category_items)
- [ ] Handles albums with no associations
- [ ] Handles albums with hundreds of releases/images
- [ ] Handles albums with no ranked_items (no jobs scheduled)
- [ ] Handles albums in multiple ranking configurations (all recalculated)

### Transaction Rollback Scenarios
- [ ] **Validation failure**: Source album invalid state - transaction rolls back, error returned
- [ ] **Constraint violation**: Unexpected unique constraint hit - transaction rolls back, no changes
- [ ] **Database error**: Connection lost mid-merge - transaction rolls back automatically
- [ ] **Source album deletion fails**: All reassignments rolled back, albums unchanged
- [ ] **After rollback**: Both albums remain in original state, can retry merge
- [ ] **No background jobs scheduled** if transaction fails (jobs only queued after commit)

## Design Decisions

### Why Text Input for Album ID Instead of Searchable Dropdown?
- Admin already knows the duplicate's ID from browsing the site
- Simpler implementation (no search configuration needed)
- Faster workflow - just paste the ID
- Clear mental model: viewing target, entering source
- No ambiguity about which album is which (current page = target, entered ID = source)
- Matches user's stated workflow: "I will already know the ID"

### Why Service Object Pattern?
- Complex multi-model operation
- Reusable logic outside Avo context
- Easier to test in isolation
- Clear Result object for success/failure handling
- Matches existing patterns (`Categories::Merger`)

### Why Inline (No Background Job)?
- Typical album merge completes in seconds
- Admin needs immediate feedback
- Transaction semantics work better inline
- Simpler error handling and rollback
- User explicitly requested inline processing

### Why Find-or-Create for Join Tables?
- Prevents unique constraint violations
- Gracefully handles albums already sharing artists/categories/lists
- Preserves existing associations
- Idempotent operation (can retry safely)

### Why Recalculate Rankings After Merge?
- Ranked_items simply reassign to target album (no conflict possible due to unique constraint)
- Merging changes the data landscape - weights and rankings need to reflect new reality
- Weight calculation depends on list composition (which may change from reassigned list_items)
- Rankings depend on weights (must recalculate weights first, then rankings)
- 5-minute delay ensures weight job completes before ranking job runs
- Background jobs handle expensive calculations without blocking admin

### Why Direct Reassignment for Most Associations?
- Faster than find-or-create
- No unique constraints to violate
- Simpler code
- Lower database overhead

### Why Database Transaction is Critical?
- **Prevents partial merges**: Without transaction, failure halfway through leaves albums in inconsistent state
- **Automatic rollback**: Any error (validation, constraint violation, DB error) automatically undoes all changes
- **Data integrity**: Ensures source album is either fully merged and deleted, or remains completely unchanged
- **No manual cleanup needed**: Rails handles rollback automatically - no orphaned records
- **Safe to retry**: Failed merge leaves both albums in original state - admin can fix issue and retry
- **Example failure scenarios**:
  - If `destroy_source_album` fails, all reassignments are rolled back
  - If unique constraint violated on list_items, nothing is changed
  - If database connection lost mid-merge, all changes are rolled back

## Risk Assessment

### High Risk - MITIGATED BY TRANSACTION
- **❌ Data loss if merge fails mid-operation**
  - ✅ **MITIGATED**: Transaction wraps entire operation - automatic rollback on any error
  - ✅ **RESULT**: No partial merges possible - albums remain in original state on failure
  - Testing: Test rollback scenarios (simulate DB errors, constraint violations)

- **❌ Unique constraint violations causing data corruption**
  - ✅ **MITIGATED**: Use find_or_create for constrained tables + transaction rollback
  - ✅ **RESULT**: Constraint violation triggers rollback - no changes persist
  - Testing: Test albums with overlapping associations (same artists, categories, lists)

### Medium Risk
- **Performance with albums having hundreds of releases**
  - Mitigation: Use update_all where possible
  - Mitigation: Use find_each for batch processing
  - Testing: Test with large fixture albums

- **Primary image logic conflict**
  - Mitigation: Clear priority (target primary wins)
  - Testing: Test all primary image combinations

### Low Risk
- **Search index not updated**
  - Mitigation: Use existing SearchIndexRequest queue
  - Testing: Verify unindex request created

---

## Implementation Notes

### Approach Taken

Implemented a transaction-based service object pattern for merging duplicate album records. The merger consolidates all associated data from a source album into a target album, then destroys the source album within a database transaction to ensure atomicity.

**Core Implementation**:
1. Created `Music::Album::Merger` service class with `Result` struct pattern
2. Wrapped entire merge in `ActiveRecord::Base.transaction` for rollback safety
3. Collected affected ranking configurations BEFORE merging to track jobs needed
4. Merged associations using two patterns:
   - Direct reassignment via `update_all` for simple associations
   - Find-or-create pattern for unique-constrained associations
5. Scheduled background jobs for ranking recalculation AFTER transaction commits
6. Queued target album for search re-indexing post-merge

**Transaction Flow**:
```ruby
ActiveRecord::Base.transaction do
  collect_affected_ranking_configurations
  merge_all_associations
  destroy_source_album
end
# Post-commit operations:
reindex_target_album
schedule_ranking_recalculation
```

### Files Created

**Service Class**:
- `web-app/app/lib/music/album/merger.rb` - Transaction-based merger service with error handling

**Avo Admin Action**:
- `web-app/app/avo/actions/music/merge_album.rb` - Admin UI action using Avo 3.x syntax (fields in `def fields` method)

**Test Files**:
- `web-app/test/lib/music/album/merger_test.rb` - 16 tests covering merge functionality, error handling, and ranking recalculation

**Documentation**:
- `docs/lib/music/album/merger.md` - Comprehensive service documentation (8KB)
- Updated `docs/models/music/album.md` - Added ranked_items association and merge section
- Updated `docs/models/music/song.md` - Added ranked_items association

### Files Modified

**Models**:
- `web-app/app/models/music/album.rb` - Added `has_many :ranked_items, as: :item, dependent: :destroy` association
- `web-app/app/models/music/song.rb` - Added `has_many :ranked_items, as: :item, dependent: :destroy` association

**Avo Resources**:
- `web-app/app/avo/resources/music_album.rb` - Registered `Avo::Actions::Music::MergeAlbum` in actions list

### Challenges Encountered

**Challenge 1: Avo 3.x Deprecated API**
- **Issue**: Initial implementation used deprecated field syntax at class level
- **Error**: `Avo::DeprecatedAPIError: This API was deprecated. Please use the field method inside the fields method.`
- **Solution**: Moved field definitions into `def fields` method per Avo 3.x standards

**Challenge 2: Ranked Items Unique Constraint Conflicts**
- **Issue**: Attempting to reassign source ranked_items to target caused unique constraint violations when both albums existed in same ranking configuration
- **Initial approach**: Complex conflict resolution with delete/update logic
- **User feedback**: "i don't think we need to merge artists" and "are we merging artists?"
- **Final solution**:
  - Added `has_many :ranked_items` to album model with `dependent: :destroy`
  - Let Rails automatically destroy source ranked_items with source album
  - Preserve target album rankings (more likely to be correct)
  - Recalculate affected configurations via background jobs

**Challenge 3: Search Index Update**
- **User feedback**: "i feel like we should" queue target album for reindexing
- **Issue**: Target album gains new associations (categories, releases, etc.) that affect search index
- **Solution**: Added explicit `SearchIndexRequest.create!` for target album after merge
- **Note**: Source album unindexing handled automatically by `SearchIndexable` concern's `after_destroy` callback

### Deviations from Plan

**1. Artist Merging Removed**
- **Original plan**: Merge album_artists using find_or_create pattern
- **User feedback**: "i don't think i want to do that... it's safe to assume the use case for this is for dupe albums"
- **Rationale**: Merging is for duplicate album entries (same album imported multiple times), not for combining different albums
- **Impact**: Simpler code, prevents data corruption from mixing different albums

**2. Ranked Items Handling Simplified**
- **Original plan**: Complex reassignment with conflict resolution (delete duplicates, update non-duplicates)
- **User realization**: "it sounds like we might not even have to delete ranked_items manually? when we delete the one we are merging it will destroy the ranked items already"
- **Final approach**: Added `ranked_items` association with `dependent: :destroy`, let Rails handle cleanup
- **Benefit**: Simpler, more maintainable code relying on Rails conventions

**3. Search Unindexing Made Automatic**
- **Original plan**: Manual `SearchIndexRequest.create!` for unindexing source album
- **User feedback**: "album already is including SearchIndexable so i don't think we need to have a step to delete the index"
- **Final approach**: Rely on `SearchIndexable` concern's `after_destroy` callback
- **Benefit**: DRY principle, uses existing infrastructure

**4. Credits Skipped**
- **Plan noted**: Skip credits as "not currently populated"
- **Implementation**: Credits not merged (association exists but no data)
- **Future**: Will add to merger when credits are actively used

### Code Examples

**Service Usage**:
```ruby
result = Music::Album::Merger.call(
  source: duplicate_album,
  target: canonical_album
)

if result.success?
  puts "Merged successfully"
else
  puts "Errors: #{result.errors.join(', ')}"
end
```

**Transaction Safety**:
```ruby
def call
  ActiveRecord::Base.transaction do
    collect_affected_ranking_configurations
    merge_all_associations
    destroy_source_album
  end
  # Only executed if transaction succeeds
  reindex_target_album
  schedule_ranking_recalculation

  Result.new(success?: true, data: target_album, errors: [])
rescue => error
  # Transaction automatically rolled back
  Result.new(success?: false, data: nil, errors: [error.message])
end
```

**Merge Patterns Used**:
```ruby
# Pattern 1: Direct reassignment (no unique constraints)
def merge_identifiers
  count = source_album.identifiers.update_all(identifiable_id: target_album.id)
  @stats[:identifiers] = count
end

# Pattern 2: Find or create (unique constraints)
def merge_category_items
  count = 0
  source_album.category_items.find_each do |category_item|
    target_album.category_items.find_or_create_by!(
      category_id: category_item.category_id
    )
    count += 1
  end
  @stats[:category_items] = count
end

# Pattern 3: Primary image conflict resolution
def merge_images
  has_target_primary = target_album.primary_image.present?

  source_album.images.find_each do |image|
    image.update!(
      parent_id: target_album.id,
      primary: has_target_primary ? false : image.primary
    )
  end
end
```

### Testing Approach

**Test Coverage**: 16 tests, 43 assertions, 0 failures
- Success scenarios (basic merge, association handling)
- Error handling (transaction rollback, validation failures)
- Duplicate handling (categories, list items with same album)
- Search indexing (unindex source, index target)
- Ranking recalculation (job scheduling for affected configs)
- Edge cases (empty albums, ranked_items destruction)

**Test Strategy**:
- Used existing fixtures (albums, artists, categories, lists)
- Mocked background job calls with Mocha expectations
- Verified transaction rollback by checking source album still exists on error
- Tested both source and target in same ranking configuration

**Key Test Patterns**:
```ruby
test "should delete source ranked_item when target already has one in same config" do
  # Both albums ranked in same config
  source_item = RankedItem.create!(item: source, config: config, rank: 5)
  target_item = RankedItem.create!(item: target, config: config, rank: 2)

  result = Merger.call(source: source, target: target)

  assert result.success?
  assert_not RankedItem.exists?(source_item.id)  # Destroyed
  assert RankedItem.exists?(target_item.id)       # Preserved
end
```

### Performance Considerations

- **Batch operations**: Used `update_all` where possible to minimize database round-trips
- **Transaction scope**: Kept transaction focused on data changes only; background jobs scheduled after commit
- **Search indexing**: Deferred to background job (SearchIndexRequest queue)
- **Ranking recalculation**: Scheduled asynchronously with 5-minute delay for sequential processing
- **Expected completion time**: Under 30 seconds for typical albums with moderate associations

**Scalability Notes**:
- Albums with hundreds of releases/images handled via `find_each` batching
- Large ranking configurations recalculated in background without blocking merge
- Transaction prevents long-running locks by excluding post-merge operations

### Future Improvements

**Potential Enhancements**:
1. **Merge preview**: Show what would be merged before executing
2. **Undo capability**: Create a merge record with original IDs for potential rollback
3. **Batch merging**: Merge multiple duplicate albums in one operation
4. **Smart artist matching**: Optionally merge artists if they appear identical (same name, same identifiers)
5. **Conflict resolution UI**: Let admin choose which data to keep when conflicts exist (e.g., which description, which release year)
6. **Merge audit trail**: Log merge operations for compliance and debugging

**Technical Improvements**:
1. **Performance metrics**: Track merge duration and association counts
2. **Dry run mode**: Execute merge logic without committing transaction
3. **Progress callbacks**: Report merge progress for long-running operations
4. **Validation warnings**: Check for data inconsistencies before merging

### Lessons Learned

**What Worked Well**:
1. **Transaction-based approach**: Automatic rollback on errors prevented partial merges
2. **Service object pattern**: Clean separation of concerns, easy to test
3. **Result struct**: Clear success/failure handling without exceptions for expected failures
4. **User feedback integration**: Quick iteration on ranked_items and artist handling
5. **Documentation-first planning**: Comprehensive spec helped guide implementation

**What Could Be Better**:
1. **Earlier model association check**: Should have verified ranked_items association existence before planning complex logic
2. **Test fixtures review**: Could have examined existing fixtures more thoroughly before writing tests
3. **Avo API version check**: Should have confirmed Avo 3.x syntax requirements earlier

**Key Insights**:
1. **DRY principle pays off**: Leveraging `SearchIndexable` and `dependent: :destroy` simplified code significantly
2. **User understanding crucial**: User's insight about use case (duplicate albums, not different albums) prevented implementing wrong feature
3. **Rails conventions are powerful**: `dependent: :destroy` and callbacks handle complex cleanup automatically
4. **Comprehensive specs enable iteration**: Detailed todo allowed quick pivots when requirements clarified

### Related PRs
- Implementation completed in single session (no PR yet)

### Documentation Updated
- ✅ Created `docs/lib/music/album/merger.md` - Complete service documentation
- ✅ Updated `docs/models/music/album.md` - Added ranked_items association and merge section
- ✅ Updated `docs/models/music/song.md` - Added ranked_items association
- ✅ Test files created with comprehensive coverage (16 tests)
- ✅ No Avo action documentation needed (per testing guide - manually tested admin UI)

---

## Related Documentation
- [Music::Album::Merger Service](../lib/music/album/merger.md) - Complete implementation documentation
- [Music::Album Model](../models/music/album.md) - Model documentation with merge section
- [Music::Song Model](../models/music/song.md) - Updated with ranked_items association
- [SearchIndexable Concern](../concerns/search_indexable.md) - Automatic indexing behavior
- [SearchIndexRequest Model](../models/search_index_request.md) - Search queue documentation
