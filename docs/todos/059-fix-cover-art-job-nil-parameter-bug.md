# 059 - Fix Cover Art Download Job Nil Parameter Bug

## Status
- **Status**: Not Started
- **Priority**: High
- **Created**: 2025-10-22
- **Started**: TBD
- **Completed**: TBD
- **Developer**: AI Agent

## Overview
Fix production bug where `Music::CoverArtDownloadJob` is being enqueued with `nil` album_id parameters, causing jobs to error when they attempt to find the album record.

## Context
- **Production Issue**: Multiple errored jobs in production due to nil parameters
- **Root Cause**: Job is being called before the album record is persisted to the database
- **Location**: `app/lib/data_importers/music/album/providers/music_brainz.rb:62`
- **Impact**: Failed background jobs, missing cover art downloads for new albums

### Why This Happens
The DataImporter system saves items **after** each provider completes (per the incremental saving architecture). However, the MusicBrainz provider calls `CoverArtDownloadJob.perform_async(album.id)` during its populate method, before returning. For new (unpersisted) albums, `album.id` is `nil` at this point.

### Existing Pattern
Other providers in the codebase (AI Description, Amazon) already handle this correctly by checking `album.persisted?` before queuing jobs. The MusicBrainz provider is missing this check.

## Requirements
- [ ] Add persistence validation before calling CoverArtDownloadJob
- [ ] Return appropriate failure result if album is not persisted
- [ ] Follow the same pattern used by other async providers (AI Description, Amazon)
- [ ] Add test coverage for the new validation
- [ ] Ensure existing tests still pass
- [ ] Verify fix doesn't break existing import workflows

## Technical Approach

### Current Code (Problematic)
**File**: `web-app/app/lib/data_importers/music/album/providers/music_brainz.rb:56-64`
```ruby
# Populate album with MusicBrainz data
populate_album_data(album, release_group_data, artists)
create_identifiers(album, release_group_data)
create_categories_from_musicbrainz_data(album, release_group_data)

# Launch cover art download job after successful import
::Music::CoverArtDownloadJob.perform_async(album.id)  # ← album.id is nil if album is new!

success_result(data_populated: data_fields_populated(release_group_data))
```

**Current Provider Order** (in `importer.rb`):
1. MusicBrainz - gets metadata
2. Amazon - enriches with product data
3. AiDescription - generates AI description

### Proposed Solution: Create Separate CoverArt Provider

**Benefits of this approach**:
- **Single Responsibility**: MusicBrainz handles metadata, CoverArt handles images
- **Extensibility**: Easy to add other cover art sources (Spotify, Amazon Images, etc.)
- **Explicit Ordering**: Clear control over when cover art download happens
- **Consistent Pattern**: Follows same async provider pattern as AI Description and Amazon
- **Better Architecture**: Cover art downloading is logically separate from metadata import

**New Provider Order**:
1. MusicBrainz - gets metadata from MusicBrainz
2. **CoverArt (NEW)** - downloads cover art from MusicBrainz Cover Art Archive
3. Amazon - enriches with product data (could add Amazon images as fallback later)
4. AiDescription - generates AI description

### Implementation Plan

#### 1. Create New CoverArt Provider
**File**: `web-app/app/lib/data_importers/music/album/providers/cover_art.rb`

Follow the pattern from `ai_description.rb`:
```ruby
module DataImporters
  module Music
    module Album
      module Providers
        # Cover Art provider for Music::Album
        # Downloads album cover art from MusicBrainz Cover Art Archive
        # This is an async provider - launches background job and returns success immediately
        class CoverArt < DataImporters::ProviderBase
          def populate(album, query:)
            # Validate album is persisted before queuing background job
            # This prevents jobs from running with nil IDs when album is new
            return failure_result(errors: ["Album must be persisted before queuing cover art download job"]) unless album.persisted?

            # Launch background job for cover art download
            ::Music::CoverArtDownloadJob.perform_async(album.id)

            # Return success immediately - actual download happens in background
            success_result(data_populated: [:cover_art_queued])
          rescue => e
            failure_result(errors: ["Cover Art provider error: #{e.message}"])
          end
        end
      end
    end
  end
end
```

#### 2. Update Album Importer
**File**: `web-app/app/lib/data_importers/music/album/importer.rb`

Add CoverArt provider after MusicBrainz:
```ruby
def providers
  @providers ||= [
    Providers::MusicBrainz.new,
    Providers::CoverArt.new,      # NEW
    Providers::Amazon.new,
    Providers::AiDescription.new
  ]
end
```

#### 3. Remove Job Call from MusicBrainz Provider
**File**: `web-app/app/lib/data_importers/music/album/providers/music_brainz.rb`

Remove lines 61-62:
```ruby
# DELETE THESE LINES:
# Launch cover art download job after successful import
::Music::CoverArtDownloadJob.perform_async(album.id)
```

#### 4. Future Extensibility
Later, the CoverArt provider could be extended to try multiple sources:
```ruby
# Future enhancement example
def populate(album, query:)
  return failure_result(...) unless album.persisted?

  # Try MusicBrainz first, fallback to Spotify, then Amazon
  source = determine_best_cover_art_source(album)

  case source
  when :musicbrainz
    ::Music::CoverArtDownloadJob.perform_async(album.id)
  when :spotify
    ::Music::SpotifyCoverArtJob.perform_async(album.id)
  when :amazon
    ::Music::AmazonCoverArtJob.perform_async(album.id)
  end

  success_result(data_populated: [:cover_art_queued])
end
```

### Alternative Considered (Rejected)
**Option 1**: Add persistence check directly in MusicBrainz provider
- ❌ Violates Single Responsibility Principle
- ❌ Couples metadata import with image downloading
- ❌ Harder to extend with other cover art sources

**Option 2**: Use `after_commit` callback on Album model
- ❌ Would trigger for ALL album saves, not just imports
- ❌ Less explicit control
- ❌ Harder to test

**Decision**: Create separate CoverArt provider (best architecture)

## Dependencies
- None - this is a standalone bug fix

## Acceptance Criteria
- [ ] MusicBrainz provider checks `album.persisted?` before calling CoverArtDownloadJob
- [ ] Returns failure result with descriptive error if album not persisted
- [ ] New test: validates behavior when album is not persisted
- [ ] Existing tests still pass
- [ ] No production errors for nil album_id after deployment

## Design Decisions

### Why Check in Provider vs Model Callback?
- **Provider check is explicit**: Clear when job gets queued
- **Follows existing pattern**: ai_description.rb and amazon.rb use same approach
- **Better for testing**: Can test provider behavior independently
- **Granular control**: Only runs during import, not on every album save

### Why Return Failure vs Success?
- **Failure is more accurate**: If we can't queue the job, the provider didn't fully succeed
- **Allows retry logic**: Importer can handle the failure appropriately
- **Consistent with other providers**: ai_description.rb returns failure when not persisted
- **Visibility**: Makes the issue visible rather than silently skipping

## Test Plan

### New Files to Create
1. **Provider file**: `web-app/app/lib/data_importers/music/album/providers/cover_art.rb`
2. **Test file**: `web-app/test/lib/data_importers/music/album/providers/cover_art_test.rb`

### New Test Cases for CoverArt Provider
Follow the pattern from `ai_description_test.rb`:

1. **Test successful cover art job queueing** (persisted album)
2. **Test failure when album is not persisted**
3. **Test works with item-based import** (query is nil)

### Example Test File Structure
```ruby
# web-app/test/lib/data_importers/music/album/providers/cover_art_test.rb
require "test_helper"

module DataImporters
  module Music
    module Album
      module Providers
        class CoverArtTest < ActiveSupport::TestCase
          def setup
            @provider = CoverArt.new
            @artist = music_artists(:pink_floyd)
            @query = ImportQuery.new(artist: @artist, title: "The Wall")
            @album = music_albums(:dark_side_of_the_moon) # Use existing album from fixtures
          end

          test "populate launches CoverArtDownloadJob and returns success" do
            ::Music::CoverArtDownloadJob.expects(:perform_async).with(@album.id)

            result = @provider.populate(@album, query: @query)

            assert result.success?
            assert_equal [:cover_art_queued], result.data_populated
          end

          test "populate returns failure when album is not persisted" do
            unpersisted_album = ::Music::Album.new(title: "New Album")
            unpersisted_album.album_artists.build(artist: @artist, position: 1)

            result = @provider.populate(unpersisted_album, query: @query)

            refute result.success?
            assert_includes result.errors, "Album must be persisted before queuing cover art download job"
          end

          test "populate works with item-based import when query is nil" do
            ::Music::CoverArtDownloadJob.expects(:perform_async).with(@album.id)

            result = @provider.populate(@album, query: nil)

            assert result.success?
            assert_equal [:cover_art_queued], result.data_populated
          end
        end
      end
    end
  end
end
```

### Files to Update
1. `web-app/app/lib/data_importers/music/album/importer.rb` - Add CoverArt to providers array
2. `web-app/app/lib/data_importers/music/album/providers/music_brainz.rb` - Remove job call (lines 61-62)
3. `web-app/test/lib/data_importers/music/album/providers/music_brainz_test.rb` - Remove job stub from setup (line 17)
4. `web-app/test/lib/data_importers/music/album/importer_test.rb` - Add stub for CoverArtDownloadJob

### Test Commands
```bash
cd web-app

# Test new CoverArt provider
bin/rails test test/lib/data_importers/music/album/providers/cover_art_test.rb

# Test MusicBrainz provider still works
bin/rails test test/lib/data_importers/music/album/providers/music_brainz_test.rb

# Test importer integration
bin/rails test test/lib/data_importers/music/album/importer_test.rb

# Run all album import tests
bin/rails test test/lib/data_importers/music/album/
```

---

## Implementation Notes
*[This section will be filled out during/after implementation]*

### Approach Taken

### Key Files Changed

### Challenges Encountered

### Deviations from Plan

### Testing Approach

### Performance Considerations

### Future Improvements

### Lessons Learned

### Related PRs

### Documentation Updated
- [ ] This todo file marked complete
- [ ] Class documentation updated if needed
