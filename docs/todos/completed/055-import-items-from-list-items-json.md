# [055] - Import Albums and Create list_items from items_json

## Status
- **Status**: Completed
- **Priority**: High
- **Created**: 2025-10-19
- **Started**: 2025-10-19
- **Completed**: 2025-10-19
- **Developer**: Claude (AI Agent)

## Overview
Implement the actual album import and list_item creation from enriched `items_json` data. This is Phase 2 of the list import workflow, following the enrichment (Task 052) and validation (Task 054) phases. The service will iterate through items_json entries, import missing albums via MusicBrainz, and create list_item records with proper positioning.

## Context

### The Three-Phase Workflow

After AI parsing extracts album data from HTML lists, we now have a three-phase workflow to convert that data into verified list_items:

1. **Phase 1 - Enrichment (Task 052)**: Add MusicBrainz metadata to items_json
   - Input: `{rank, title, artists, release_year}`
   - Output: Adds `{mb_release_group_id, mb_release_group_name, mb_artist_ids, mb_artist_names, album_id, album_name}`

2. **Phase 2 - Validation (Task 054)**: AI validates matches are correct
   - Flags incorrect matches with `ai_match_invalid: true`
   - Examples: live albums matched with studio, tribute albums, artist mismatches

3. **Phase 3 - Import (THIS TASK)**: Import albums and create list_items
   - Skip AI-flagged invalid matches
   - Import missing albums via `DataImporters::Music::Album::Importer`
   - Create list_items with proper positioning

### Why This Matters

Currently, enriched and validated items_json data exists but isn't used to create actual database records. This task completes the workflow by:

- Importing albums that don't exist in our database yet
- Creating verified list_item records linking albums to lists
- Maintaining proper list ordering via position field
- Skipping invalid matches identified by AI validation

### Related Work
- **Task 052**: Implemented `Services::Lists::Music::Albums::ItemsJsonEnricher` - adds MusicBrainz metadata
- **Task 053**: Implemented items_json viewer tool - displays enrichment and validation status
- **Task 054**: Implemented `Services::Ai::Tasks::Lists::Music::Albums::ItemsJsonValidatorTask` - AI validation

## Requirements
- [x] Create service object that imports albums and creates list_items from items_json
- [x] Skip entries flagged with `ai_match_invalid: true` (failed validation)
- [x] If `album_id` present: load album directly by ID and create list_item (no import needed)
- [x] If no `album_id` but has `mb_release_group_id`: import album via `DataImporters::Music::Album::Importer`
- [x] If neither `album_id` nor `mb_release_group_id`: skip (not enriched)
- [x] Check for existing list_items before creating (prevent duplicates)
- [x] Create list_items with album as `listable` and rank as `position`
- [x] Mark created list_items as `verified: true`
- [x] Return result hash with counts (total, imported, created_directly, skipped, errors)
- [x] Create Sidekiq job to run service in background
- [x] Create Avo action to launch job from admin UI
- [x] Write comprehensive tests for service and job

## Technical Approach

### Service Object: `Services::Lists::Music::Albums::ItemsJsonImporter`

**Location**: `app/lib/services/lists/music/albums/items_json_importer.rb`

**Responsibilities**:
1. Validate list has enriched items_json data
2. Iterate through items_json["albums"] array
3. For each album entry:
   - Skip if `ai_match_invalid: true` (failed AI validation)
   - If `album_id` present: load album directly (`Music::Album.find(album_id)`)
   - If no `album_id` but has `mb_release_group_id`: import album (`DataImporters::Music::Album::Importer.call(release_group_musicbrainz_id: mb_id)`)
   - If neither: skip (not enriched)
   - Handle album load/import failures (log warning, continue processing)
   - Check for existing list_item: `list.list_items.find_by(listable: album)`
   - Create list_item if needed: `list.list_items.create!(listable: album, position: rank, verified: true)`
4. Return result hash with statistics

**Class Structure**:
```ruby
module Services
  module Lists
    module Music
      module Albums
        class ItemsJsonImporter
          Result = Struct.new(:success, :data, :message, :imported_count, :created_directly_count, :skipped_count, :error_count, keyword_init: true)

          def self.call(list:)
            new(list: list).call
          end

          def initialize(list:)
            @list = list
            @imported_count = 0
            @created_directly_count = 0
            @skipped_count = 0
            @error_count = 0
            @errors = []
          end

          def call
            validate_list!

            albums = @list.items_json["albums"]

            albums.each_with_index do |album_data, index|
              process_album(album_data, index)
            end

            Result.new(
              success: true,
              message: "Imported #{@imported_count} albums, created #{@created_directly_count} from existing albums, skipped #{@skipped_count}, #{@error_count} errors",
              imported_count: @imported_count,
              created_directly_count: @created_directly_count,
              skipped_count: @skipped_count,
              error_count: @error_count,
              data: {
                total_albums: albums.length,
                imported: @imported_count,
                created_directly: @created_directly_count,
                skipped: @skipped_count,
                errors: @error_count,
                error_messages: @errors
              }
            )
          rescue ArgumentError => e
            raise
          rescue => e
            Rails.logger.error "ItemsJsonImporter failed: #{e.message}"
            Result.new(
              success: false,
              message: "Import failed: #{e.message}",
              imported_count: @imported_count,
              created_directly_count: @created_directly_count,
              skipped_count: @skipped_count,
              error_count: @error_count,
              data: {errors: [@errors + [e.message]].flatten}
            )
          end

          private

          def validate_list!
            raise ArgumentError, "List is required" unless @list
            raise ArgumentError, "List must have items_json" unless @list.items_json.present?
            raise ArgumentError, "items_json must have albums array" unless @list.items_json["albums"].is_a?(Array)
            raise ArgumentError, "items_json albums array is empty" unless @list.items_json["albums"].any?
          end

          def process_album(album_data, index)
            # Skip if AI flagged as invalid
            if album_data["ai_match_invalid"] == true
              Rails.logger.info "Skipping album at index #{index}: AI flagged as invalid match"
              @skipped_count += 1
              return
            end

            # Skip if not enriched (no album_id and no mb_release_group_id)
            unless album_data["album_id"].present? || album_data["mb_release_group_id"].present?
              Rails.logger.info "Skipping album at index #{index}: not enriched (no album_id or mb_release_group_id)"
              @skipped_count += 1
              return
            end

            rank = album_data["rank"]

            # Load or import album
            album = load_or_import_album(album_data, index)

            unless album
              Rails.logger.error "Failed to load/import album at index #{index}: #{album_data["title"]}"
              @error_count += 1
              @errors << "Failed to load/import: #{album_data["title"]}"
              return
            end

            # Create list_item if it doesn't exist
            create_list_item_if_needed(album, rank, index)
          rescue => e
            Rails.logger.error "Error processing album at index #{index}: #{e.message}"
            @error_count += 1
            @errors << "Error at index #{index}: #{e.message}"
          end

          def load_or_import_album(album_data, index)
            # If album already exists in database, load it directly
            if album_data["album_id"].present?
              Rails.logger.info "Loading existing album at index #{index}: #{album_data["album_name"]} (ID: #{album_data["album_id"]})"
              album = ::Music::Album.find_by(id: album_data["album_id"])

              if album
                @created_directly_count += 1 if create_will_succeed?(album)
                return album
              else
                Rails.logger.warn "Album ID #{album_data["album_id"]} not found, will try import if MusicBrainz ID available"
              end
            end

            # If no album_id or album not found, try importing by MusicBrainz ID
            if album_data["mb_release_group_id"].present?
              Rails.logger.info "Importing album at index #{index}: #{album_data["title"]} (MusicBrainz ID: #{album_data["mb_release_group_id"]})"
              album = import_album(album_data["mb_release_group_id"])
              @imported_count += 1 if album && create_will_succeed?(album)
              return album
            end

            nil
          end

          def import_album(mb_release_group_id)
            result = DataImporters::Music::Album::Importer.call(
              release_group_musicbrainz_id: mb_release_group_id
            )

            if result.success?
              result.item
            else
              Rails.logger.error "Album import failed for #{mb_release_group_id}: #{result.all_errors.join(", ")}"
              nil
            end
          end

          def create_will_succeed?(album)
            !@list.list_items.exists?(listable: album)
          end

          def create_list_item_if_needed(album, rank, index)
            # Check for duplicate
            existing_item = @list.list_items.find_by(listable: album)
            if existing_item
              Rails.logger.info "List item already exists for album: #{album.title} (position: #{existing_item.position})"
              @skipped_count += 1
              return
            end

            # Create new list_item
            @list.list_items.create!(
              listable: album,
              position: rank,
              verified: true
            )

            Rails.logger.info "Created list_item for #{album.title} at position #{rank}"
          end
        end
      end
    end
  end
end
```

**Pattern to Follow**:
- Similar to `Services::Lists::Music::Albums::ItemsJsonEnricher` (task 052)
- Uses `DataImporters::Music::Album::Importer.call(release_group_musicbrainz_id:)` pattern from `/home/shane/dev/the-greatest/web-app/app/lib/data_importers/music/lists/import_from_musicbrainz_series.rb:101-115`
- Uses duplicate prevention pattern from `/home/shane/dev/the-greatest/web-app/app/lib/data_importers/music/lists/import_from_musicbrainz_series.rb:117-135`
- Returns result struct with success/failure and statistics

### Sidekiq Job: `Music::Albums::ImportListItemsFromJsonJob`

**Location**: `app/sidekiq/music/albums/import_list_items_from_json_job.rb`

**Responsibilities**:
1. Accept list_id parameter
2. Load `Music::Albums::List` record
3. Call importer service
4. Log results (success/failure, counts)
5. Handle errors with logging and re-raise

**Class Structure**:
```ruby
class Music::Albums::ImportListItemsFromJsonJob
  include Sidekiq::Job

  def perform(list_id)
    list = ::Music::Albums::List.find(list_id)

    result = Services::Lists::Music::Albums::ItemsJsonImporter.call(list: list)

    if result.success
      Rails.logger.info "ImportListItemsFromJsonJob completed for list #{list_id}: imported #{result.imported_count}, created directly #{result.created_directly_count}, skipped #{result.skipped_count}, errors #{result.error_count}"
    else
      Rails.logger.error "ImportListItemsFromJsonJob failed for list #{list_id}: #{result.message}"
    end
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.error "ImportListItemsFromJsonJob: List not found - #{e.message}"
    raise
  rescue => e
    Rails.logger.error "ImportListItemsFromJsonJob failed: #{e.message}"
    raise
  end
end
```

**Pattern to Follow**:
- Similar to `Music::Albums::EnrichListItemsJsonJob` (task 052)
- Similar to `Music::Albums::ValidateListItemsJsonJob` (task 054)
- Include `Sidekiq::Job` module
- Use default queue (no queue_as needed)
- Rescue errors with logging and re-raise

### Avo Action: `Avo::Actions::Lists::Music::Albums::ImportItemsFromJson`

**Location**: `app/avo/actions/lists/music/albums/import_items_from_json.rb`

**Responsibilities**:
1. Validate selected lists are `Music::Albums::List`
2. Validate lists have enriched items_json data (at least one album with `mb_release_group_id`)
3. Queue import job for each valid list
4. Return success message with count
5. Log warnings for skipped lists

**Class Structure**:
```ruby
class Avo::Actions::Lists::Music::Albums::ImportItemsFromJson < Avo::BaseAction
  self.name = "Import albums from items_json"
  self.message = "This will import albums from MusicBrainz based on enriched items_json data and create list_items. Albums flagged as invalid by AI will be skipped."
  self.confirm_button_label = "Import albums"

  def handle(query:, fields:, current_user:, resource:, **args)
    query.pluck(:id)

    valid_lists = query.select do |list|
      is_album_list = list.is_a?(::Music::Albums::List)
      has_enriched_items = list.items_json.present? &&
                          list.items_json["albums"].is_a?(Array) &&
                          list.items_json["albums"].any? { |a| a["mb_release_group_id"].present? }

      unless is_album_list
        Rails.logger.warn "Skipping non-album list: #{list.name} (ID: #{list.id}, Type: #{list.class})"
      end

      unless has_enriched_items
        Rails.logger.warn "Skipping list without enriched items_json: #{list.name} (ID: #{list.id})"
      end

      is_album_list && has_enriched_items
    end

    if valid_lists.empty?
      return error "No valid lists found. Lists must be Music::Albums::List with enriched items_json data (albums with mb_release_group_id)."
    end

    valid_lists.each do |list|
      Music::Albums::ImportListItemsFromJsonJob.perform_async(list.id)
    end

    succeed "#{valid_lists.length} list(s) queued for album import. Each list will be processed in a separate background job."
  end
end
```

**Pattern to Follow**:
- Similar to `Avo::Actions::Lists::Music::Albums::EnrichItemsJson` (task 052)
- Similar to `Avo::Actions::Lists::Music::Albums::ValidateItemsJson` (task 054)
- Extend `Avo::BaseAction`
- Validate records before queuing
- Use `perform_async(list.id)` to queue jobs

**Registration**: Add to `app/avo/resources/music_albums_list.rb`:
```ruby
def actions
  super
  action Avo::Actions::Lists::ImportFromMusicbrainzSeries
  action Avo::Actions::Lists::Music::Albums::EnrichItemsJson
  action Avo::Actions::Lists::Music::Albums::ValidateItemsJson
  action Avo::Actions::Lists::Music::Albums::ImportItemsFromJson
end
```

## Dependencies
- **Existing**: `Music::Albums::List` model with `items_json` JSONB field
- **Existing**: `Services::Lists::Music::Albums::ItemsJsonEnricher` - enrichment service (task 052)
- **Existing**: `Services::Ai::Tasks::Lists::Music::Albums::ItemsJsonValidatorTask` - validation service (task 054)
- **Existing**: `DataImporters::Music::Album::Importer` - album import service
- **Existing**: `Music::Album.with_musicbrainz_release_group_id(mbid)` - scope for finding albums by MusicBrainz ID
- **Existing**: `ListItem` model with polymorphic `listable` association
- **New**: Sidekiq job generator (`bin/rails generate sidekiq:job music/albums/import_list_items_from_json`)

## Acceptance Criteria
- [x] Service validates list has enriched items_json before processing
- [x] Service skips albums with `ai_match_invalid: true` (failed AI validation)
- [x] Service loads existing albums directly when `album_id` is present (no import needed)
- [x] Service imports albums via `DataImporters::Music::Album::Importer` when only `mb_release_group_id` available
- [x] Service skips albums with neither `album_id` nor `mb_release_group_id` (not enriched)
- [x] Service handles album load/import failures gracefully (logs error, continues processing)
- [x] Service prevents duplicate list_items using `find_by(listable: album)` check
- [x] Service creates list_items with correct position (from rank field)
- [x] Service marks created list_items as `verified: true`
- [x] Service returns result struct with success/failure and statistics (imported, created_directly, skipped, errors)
- [x] Service tracks separate counts for imported albums vs directly loaded albums
- [x] Sidekiq job queues and executes service successfully
- [x] Sidekiq job logs results (imported, created_directly, skipped, errors)
- [x] Avo action validates lists have enriched data before queuing
- [x] Avo action provides clear error messages for invalid selections
- [x] All components have comprehensive test coverage
- [x] Tests verify list_items are created with correct attributes
- [x] Tests verify duplicate prevention works
- [x] Tests verify AI-flagged albums are skipped
- [x] Tests verify albums loaded directly by ID when available
- [x] Tests verify albums imported only when needed

## Design Decisions

### 1. Load Existing Albums by ID, Import Only When Needed
**Decision**: Check for `album_id` first and load directly if present. Only import via `release_group_musicbrainz_id` if album doesn't exist in database.
**Rationale**: The enricher (task 052) already checks if albums exist and adds `album_id`/`album_name` when found. Loading by ID is much faster than importing (no MusicBrainz API call, no provider chain). Only albums truly missing from our database need import.
**Efficiency**: For lists of 100 albums where 80 already exist, this saves 80 MusicBrainz API calls and all the associated provider processing.
**Alternative Considered**: Always use MusicBrainz ID lookup even for existing albums (rejected - unnecessary API calls and processing).

### 2. Skip AI-Flagged Invalid Matches
**Decision**: Automatically skip albums with `ai_match_invalid: true`, don't attempt import.
**Rationale**: These are known incorrect matches (e.g., live album matched with studio). Importing them would create incorrect list_items. Admin can manually fix items_json and re-run import.
**Visual Feedback**: Items JSON viewer tool (task 053) highlights these in red, making them easy to identify and fix.

### 3. Mark list_items as verified: true
**Decision**: Set `verified: true` on all created list_items.
**Rationale**: These items have been through enrichment and AI validation, and the albums successfully imported from MusicBrainz. This is higher quality than manual list creation. The `verified` field distinguishes them from unverified metadata-only items.
**Alternative Considered**: Leave verified as false until manual review (rejected - unnecessary barrier, data is already validated).

### 4. Graceful Failure Handling
**Decision**: Log album import failures but continue processing remaining albums.
**Rationale**: One failed import shouldn't block the entire list. Service returns statistics showing how many succeeded/failed, allowing admin to retry just the failures if needed.
**Pattern**: Same as enricher (task 052) - partial success is useful, not just all-or-nothing.

### 5. Duplicate Prevention Strategy
**Decision**: Check for existing list_items using `find_by(listable: album)` before creating.
**Rationale**: Prevents duplicate entries if service is run multiple times on same list. Database has unique constraint on `[list_id, listable_type, listable_id]` but explicit check provides better error handling.
**Pattern**: Matches existing list import pattern from `/home/shane/dev/the-greatest/web-app/app/lib/data_importers/music/lists/import_from_musicbrainz_series.rb:117-135`.

### 6. Position from rank Field
**Decision**: Use the `rank` field from items_json as the list_item `position`.
**Rationale**: The rank represents the album's position in the original list (e.g., #1 album, #2 album). This preserves the list's intended ordering.
**Note**: ListItem model validates position must be > 0, which aligns with typical list numbering (1, 2, 3...).

### 7. Separate Service Namespace
**Decision**: Use `Services::Lists::Music::Albums::` namespace, not `DataImporters::`.
**Rationale**: This isn't importing data from an external source - it's orchestrating existing importers and creating list_items from internal data (items_json). Matches enricher pattern.
**Consistency**: All items_json operations under same namespace: `ItemsJsonEnricher`, `ItemsJsonValidatorTask`, `ItemsJsonImporter`.

### 8. Re-run Safety (Idempotency)
**Decision**: Service can be safely re-run on the same list.
**Rationale**: Duplicate prevention ensures albums won't be duplicated. Missing albums will be imported. Failed imports can be retried. This makes the workflow flexible and forgiving.
**Implementation**: Check both album existence and list_item existence before creating.

### 9. Error Counting Strategy
**Decision**: Track four categories: imported, created_directly, skipped, errors.
**Rationale**:
- **Imported**: New albums imported from MusicBrainz and list_items created
- **Created Directly**: List_items created from albums already in database (no import needed)
- **Skipped**: Intentionally skipped (not enriched, AI flagged, duplicate)
- **Errors**: Unexpected failures (album not found, import failed, exception thrown)
This gives admin clear picture of efficiency - how many albums already existed vs needed import.

### 10. Job Queue Selection
**Decision**: Use default queue (not serial).
**Rationale**: Album imports can run in parallel, no rate limiting concerns. Each list processed independently in separate job allows concurrent processing.
**Alternative Considered**: Serial queue for MusicBrainz API calls (rejected - MusicBrainz has reasonable rate limits, importer handles throttling).

## Implementation Notes

### Approach Taken
Implemented the complete three-phase list import workflow as planned:

1. **Service Object** (`Services::Lists::Music::Albums::ItemsJsonImporter`): Handles the core import logic with validation, album loading/importing, and list_item creation.
2. **Sidekiq Job** (`Music::Albums::ImportListItemsFromJsonJob`): Background job wrapper for the service.
3. **Avo Action** (`Avo::Actions::Lists::Music::Albums::ImportItemsFromJson`): Admin UI integration for queuing import jobs.

The implementation followed the exact structure outlined in the technical approach section, with the service using a `Result` struct pattern for consistent response handling.

### Key Files Changed

**Created:**
- `app/lib/services/lists/music/albums/items_json_importer.rb` - Main service object (159 lines)
- `app/sidekiq/music/albums/import_list_items_from_json_job.rb` - Sidekiq job (22 lines)
- `app/avo/actions/lists/music/albums/import_items_from_json.rb` - Avo action (37 lines)
- `test/lib/services/lists/music/albums/items_json_importer_test.rb` - Service tests (16 test cases, 97 assertions)
- `test/sidekiq/music/albums/import_list_items_from_json_job_test.rb` - Job tests (6 test cases)

**Modified:**
- `app/avo/resources/music_albums_list.rb:18` - Registered new action
- `test/fixtures/lists.yml:124-131` - Added `music_albums_list_for_import` fixture for testing

### Challenges Encountered

**Test Fixture Conflicts**: Initial tests failed because the test setup used `music_albums_list` which already had associated list_items in fixtures. When tests tried to create list_items for the same albums, the service correctly detected duplicates and skipped them, causing test assertions to fail.

**Solution**: Added a dedicated `music_albums_list_for_import` fixture with no associated list_items for clean test isolation.

**Mocking Pattern**: Initially used `OpenStruct` for mocking importer results, which required an extra require statement. Switched to Mocha's `stub()` method for cleaner, more idiomatic test mocking.

### Deviations from Plan
None - the implementation followed the technical approach exactly as specified.

### Code Examples

**Service Usage:**
```ruby
# From the Sidekiq job
result = Services::Lists::Music::Albums::ItemsJsonImporter.call(list: list)

if result.success
  # Result provides detailed statistics
  puts "Imported: #{result.imported_count}"
  puts "Created directly: #{result.created_directly_count}"
  puts "Skipped: #{result.skipped_count}"
  puts "Errors: #{result.error_count}"
end
```

**Key Service Logic** (app/lib/services/lists/music/albums/items_json_importer.rb:87-119):
```ruby
def load_or_import_album(album_data, index)
  # Try loading by album_id first (fast path)
  if album_data["album_id"].present?
    album = ::Music::Album.find_by(id: album_data["album_id"])
    if album
      @created_directly_count += 1 if create_will_succeed?(album)
      return album
    end
  end

  # Fall back to import via MusicBrainz (slow path)
  if album_data["mb_release_group_id"].present?
    album = import_album(album_data["mb_release_group_id"])
    @imported_count += 1 if album && create_will_succeed?(album)
    return album
  end

  nil
end
```

### Testing Approach

**Service Tests** (16 test cases covering):
- Validation: List presence, items_json structure, albums array
- AI flagged albums: Correctly skipped when `ai_match_invalid: true`
- Enrichment states: Skipped when missing both `album_id` and `mb_release_group_id`
- Direct loading: Created list_items for albums that already exist in database
- Importing: Called album importer when only MusicBrainz ID available
- Duplicate prevention: No duplicate list_items created on re-runs
- Error handling: Import failures, missing albums, exceptions
- Fallback behavior: album_id not found → tries import
- Mixed scenarios: Multiple albums with different states processed correctly
- Result structure: Proper statistics tracking and result object

**Job Tests** (6 test cases covering):
- Service invocation on success/failure
- ActiveRecord::RecordNotFound handling
- Unexpected error handling
- Job enqueueing with `perform_async`
- Correct list loading by ID

**Edge Cases Discovered:**
- Album ID in items_json but album deleted from database → gracefully falls back to import
- Duplicate detection works across re-runs
- Exceptions in one album don't stop processing of remaining albums

### Performance Considerations

**Efficiency Optimizations:**
- **Fast path for existing albums**: Service checks `album_id` first and loads directly via `find_by(id:)` instead of always importing via MusicBrainz API
- **Duplicate prevention**: Uses `exists?(listable: album)` check before creating list_items
- **Idempotent design**: Service can be safely re-run on same list without creating duplicates
- **Separate count tracking**: Distinguishes between imported albums (slow) and directly loaded albums (fast) for performance visibility

**Expected Performance:**
- For a 100-album list where 80 already exist: Service makes only 20 MusicBrainz API calls instead of 100
- List_item creation is minimal (single INSERT per album)
- Background job processing allows non-blocking admin UI

### Future Improvements

**Potential Enhancements:**
1. **Batch progress updates**: Store import progress in list metadata for large lists
2. **Retry mechanism**: Automatically retry failed imports after delay
3. **Email notifications**: Notify submitter when import completes (especially for large lists)
4. **Import preview**: Show what will be imported/skipped before executing
5. **Partial re-import**: Allow re-running only failed albums instead of entire list
6. **Album matching improvements**: Add fuzzy matching for cases where enrichment found wrong MusicBrainz ID

### Lessons Learned

**What Worked Well:**
- Following existing patterns (ItemsJsonEnricher) made implementation straightforward
- Result struct pattern provides clear success/failure handling and detailed statistics
- Separate counts (imported vs created_directly) give visibility into efficiency
- Comprehensive validation prevents cryptic errors
- Graceful error handling allows partial success

**What Could Be Better:**
- Could add progress tracking for very large lists (100+ albums)
- Could optimize by batching list_item creation instead of individual creates
- Could add more detailed error messages (include album title in errors)

### Documentation Updated
- [x] This task file updated with implementation notes
- [x] Class documentation created for ItemsJsonImporter service → `docs/lib/services/lists/music/albums/items_json_importer.md`
- [x] Class documentation created for ImportListItemsFromJsonJob → `docs/sidekiq/music/albums/import_list_items_from_json_job.md`
- [x] ImportItemsFromJson action (not documented per testing.md - Avo actions are admin UI components not requiring docs)
- [x] Main todo.md updated with completion date
