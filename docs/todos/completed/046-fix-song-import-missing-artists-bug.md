# 046 - Fix Song Import Missing Artists Bug

## Status
- **Status**: Completed
- **Priority**: High
- **Created**: 2025-10-05
- **Started**: 2025-10-05
- **Completed**: 2025-10-05
- **Developer**: Claude

## Overview
Fix critical bug in song import system where songs were being created without associated artists due to improper handling of unpersisted artist records. Additionally, standardize the MusicBrainz provider naming to match existing conventions.

## Context
- During manual testing of task 044 (import song lists from MusicBrainz series), discovered many songs with no associated artists
- This should never happen - every song should have at least one artist
- If artist import fails or returns unpersisted artist, the SongArtist association should not be created
- The Recording provider class name was inconsistent with other providers (should be MusicBrainz like Artist/Album providers)

## Requirements
- [x] Write failing test that reproduces the missing artists bug
- [x] Fix provider to only create SongArtist associations when artist is persisted
- [x] Rename Recording provider class to MusicBrainz for consistency
- [x] Update all references to the renamed provider
- [x] Ensure all existing tests continue to pass
- [x] Add test coverage for the unpersisted artist edge case

## Technical Approach

### Root Cause Analysis
The bug was in `DataImporters::Music::Song::Providers::Musicbrainz::Recording#import_artists` (line 126):

```ruby
if artist_result.success? && artist_result.item
  song.song_artists.find_or_initialize_by(
    artist: artist_result.item,
    position: index + 1
  )
end
```

**Problem**: `find_or_initialize_by` creates SongArtist associations even when `artist_result.item` is unpersisted. When the song is saved by the importer base (via `item.save!`), these associations fail validation silently, resulting in songs with no artists.

**Solution**: Add `.persisted?` check to ensure only valid, persisted artists create associations.

### Naming Inconsistency
Other providers follow the pattern:
- `DataImporters::Music::Artist::Providers::MusicBrainz`
- `DataImporters::Music::Album::Providers::MusicBrainz`

But song provider was:
- `DataImporters::Music::Song::Providers::Musicbrainz::Recording` ❌

Should be:
- `DataImporters::Music::Song::Providers::Musicbrainz::MusicBrainz` ✓

## Dependencies
- Existing DataImporters framework (ImporterBase, ProviderBase)
- Music::Song, Music::Artist, Music::SongArtist models
- Task 044 implementation (song list imports)

## Acceptance Criteria
- [x] Songs cannot be created with unpersisted artist associations
- [x] Existing tests continue to pass
- [x] New test specifically validates unpersisted artist handling
- [x] Provider class naming matches established conventions
- [x] All importer references updated to new class name

## Design Decisions
- **Check persisted state**: Use `.persisted?` rather than other validation checks because it's the most direct indicator of whether an artist can be safely associated
- **Fail gracefully**: Log error but don't fail entire song import if one artist fails - song data is still valuable
- **Rename provider**: Follow established naming conventions for maintainability and AI agent comprehension

---

## Implementation Notes

### Approach Taken
1. **Wrote failing test first** to reproduce the bug with unpersisted artist scenario
2. **Added `.persisted?` check** to the artist import condition
3. **Renamed provider class** from `Recording` to `MusicBrainz`
4. **Updated all references** in importer and log messages
5. **Verified all tests pass** including new test case

### Key Files Changed

**Modified:**
- `app/lib/data_importers/music/song/providers/musicbrainz/recording.rb` → `music_brainz.rb` (renamed)
  - Line 8: Class renamed `Recording` → `MusicBrainz`
  - Line 126: Added `.persisted?` check to artist association condition
  - Lines 11, 20, 26, 40, 43: Updated log messages from "Recording provider" → "MusicBrainz provider"
- `app/lib/data_importers/music/song/importer.rb`
  - Line 20: Updated provider instantiation `Recording.new` → `MusicBrainz.new`
- `test/lib/data_importers/music/song/importer_test.rb`
  - Line 347: Added assertion for orphaned song_artists count
  - Lines 350-399: New test `test_call_does_not_create_song_artist_when_artist_import_returns_unpersisted_artist`
- `app/lib/music/musicbrainz/base_client.rb`
  - Line 4: Added `require "faraday/follow_redirects"`
  - Line 47: Added redirect handling `conn.response :follow_redirects, limit: 3`
- `Gemfile`
  - Line 91: Added `gem "faraday-follow_redirects"`
- `app/models/music/song.rb`
  - Line 38-39: Added `has_many :list_items, as: :listable` and `has_many :lists, through: :list_items` associations

### Challenges Encountered

**1. Silent Validation Failures**
- SongArtist associations were being created with unpersisted artists
- ActiveRecord didn't raise errors - associations just weren't saved
- Only way to detect was through careful logging and database inspection

**2. Test Coverage Gap**
- Original tests mocked artist import to always return persisted artists
- Edge case of unpersisted artist (validation failure) wasn't tested
- New test specifically validates this scenario

**3. MusicBrainz 301 Redirects Not Followed**
- MusicBrainz API returns 301 redirects when recording IDs are merged/changed
- BaseClient only handled 200 status codes, treated 301 as "Unexpected status"
- Browser followed redirects automatically, but Faraday needed explicit configuration
- Solution: Added `faraday-follow_redirects` middleware with limit of 3 hops
- This is common when MusicBrainz recordings are consolidated/deduplicated

### Code Examples

**Before (Bug):**
```ruby
if artist_result.success? && artist_result.item
  song.song_artists.find_or_initialize_by(
    artist: artist_result.item,
    position: index + 1
  )
end
```

**After (Fixed):**
```ruby
# Only create SongArtist if artist import succeeded AND artist is persisted
if artist_result.success? && artist_result.item&.persisted?
  song.song_artists.find_or_initialize_by(
    artist: artist_result.item,
    position: index + 1
  )
end
```

**New Test Case:**
```ruby
test "call does not create song_artist when artist import returns unpersisted artist" do
  # Mock artist importer to return success but with unpersisted artist (simulates validation failure)
  unpersisted_artist = ::Music::Artist.new(name: "Unpersisted Artist")
  artist_result = DataImporters::ImportResult.new(
    item: unpersisted_artist,
    provider_results: [],
    success: true
  )
  DataImporters::Music::Artist::Importer.stubs(:call).returns(artist_result)

  result = Importer.call(musicbrainz_recording_id: mbid)

  # Critical: Should NOT have any artists or song_artists because artist wasn't persisted
  assert_equal 0, result.item.artists.count, "Should not associate unpersisted artists"
  assert_equal 0, result.item.song_artists.count, "Should not create SongArtist for unpersisted artists"
end
```

**Redirect Handling Fix:**
```ruby
# Before (301 redirects caused errors)
def build_connection
  Faraday.new(url: config.api_url) do |conn|
    conn.options.timeout = config.timeout
    conn.adapter Faraday.default_adapter
  end
end

# After (redirects followed automatically)
def build_connection
  Faraday.new(url: config.api_url) do |conn|
    conn.options.timeout = config.timeout

    # Follow redirects automatically (for MusicBrainz recording redirects)
    conn.response :follow_redirects, limit: 3

    conn.adapter Faraday.default_adapter
  end
end
```

### Testing Approach

**Test-Driven Bug Fix:**
1. Wrote failing test that reproduced the bug (test failed as expected)
2. Made minimal change to fix the bug (added `.persisted?` check)
3. Verified test now passes
4. Ran full test suite to ensure no regressions

**Test Coverage:**
- 42 song importer tests passing (added 1 new test, modified 1 existing)
- 7 series import tests passing (end-to-end verification)
- New test specifically validates unpersisted artist scenario

### Performance Considerations
- `.persisted?` check is very fast (just checks `id` presence)
- No additional database queries added
- Fix prevents orphaned association records from being created

### Deviations from Plan

**Additional Fix: HTTP Redirect Handling**
- Not in original plan, but discovered during manual testing/re-import
- Added redirect following to MusicBrainz client to handle 301 responses
- Required adding `faraday-follow_redirects` gem dependency
- Critical for production use since MusicBrainz frequently redirects merged recordings

### Future Improvements
1. **Validate artist success more strictly**: Consider failing song import entirely if no artists can be imported (configurable behavior)
2. **Provider execution tracking**: Track which providers have run on items to enable selective re-runs
3. **Better error aggregation**: Surface artist import failures more prominently in import results
4. **Bulk re-import script**: Create Rake task or admin action to re-import songs without artists
5. **Redirect logging**: Log when redirects occur to track MusicBrainz ID merges

### Lessons Learned

**1. ActiveRecord Association Validation Can Be Silent**
- `find_or_initialize_by` creates associations even with invalid references
- Associations with unpersisted records fail validation but don't raise errors
- Always verify `.persisted?` before creating associations programmatically

**2. Test Edge Cases Explicitly**
- Happy path tests aren't enough
- Need tests for validation failures, API failures, and unpersisted records
- Mock both success and failure scenarios in unit tests

**3. Naming Consistency Matters**
- Inconsistent naming confuses both developers and AI agents
- Following established conventions makes codebase more maintainable
- Class names should clearly indicate their purpose and data source

**4. Logging Is Critical for Debugging**
- Comprehensive logging made it easy to identify the exact failure point
- Log prefixes (`[SONG_IMPORT]`) help filter and trace operations
- Always log `persisted?` and `valid?` status during imports

**5. HTTP Clients Don't Always Follow Redirects**
- Faraday requires explicit middleware to follow redirects (not automatic like browsers)
- External APIs like MusicBrainz use redirects for resource consolidation
- Always configure redirect handling for production API clients
- Set reasonable redirect limits (3-5 hops) to prevent infinite loops

**6. Manual Testing Reveals Production Issues**
- The redirect issue only appeared during manual re-import of real data
- Unit tests with mocked responses didn't catch it
- Always test against real APIs in development/staging environments

### Related PRs
*To be added when PR is created*

### Manual Model Changes

**Music::Song List Associations (User-Added)**
Added polymorphic list associations to enable songs to appear in ranked lists:
```ruby
has_many :list_items, as: :listable, dependent: :destroy
has_many :lists, through: :list_items
```

This was required for the song list import feature (task 044) but was missed in the original implementation.

### Bulk Re-Import Query

For finding and re-importing songs without artists:

```ruby
# Find all songs without any artists
Music::Song.left_joins(:song_artists)
  .where(music_song_artists: { id: nil })
  .find_each do |song|
    mb_identifier = song.identifiers.find_by(identifier_type: :music_musicbrainz_recording_id)

    if mb_identifier.present?
      puts "Re-importing song: #{song.title} (#{mb_identifier.value})"
      result = DataImporters::Music::Song::Importer.call(
        musicbrainz_recording_id: mb_identifier.value,
        force_providers: true
      )

      if result.success?
        puts "  ✓ Success - Artists: #{result.item.artists.map(&:name).join(', ')}"
      else
        puts "  ✗ Failed - #{result.all_errors.join(', ')}"
      end
    else
      puts "Skipping song without MusicBrainz ID: #{song.title} (ID: #{song.id})"
    end
  end
```

**Key features:**
- Uses `left_joins` to find songs without SongArtist records
- Gracefully handles songs without MusicBrainz identifiers
- Uses `force_providers: true` to re-run providers on existing songs
- Provides progress feedback during bulk import

### Documentation Updated
- [x] Task documentation created (this file)
- [x] Documented manual model changes (list associations)
- [x] Provided bulk re-import query for production use
- [x] Created provider documentation: `docs/lib/data_importers/music/song/providers/music_brainz.md`
- [ ] Update DataImporters feature documentation to mention persisted? checks
- [ ] Update AGENTS.md with lessons about testing association edge cases
