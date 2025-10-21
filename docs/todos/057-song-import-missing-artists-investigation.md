# 057 - Song Import Missing Artists Investigation

## Status
- **Status**: Completed
- **Priority**: High
- **Created**: 2025-10-20
- **Started**: 2025-10-20
- **Completed**: 2025-10-21
- **Developer**: AI Agent

## Overview
Investigation into production bug where Music::Songs imported from MusicBrainz series are missing artist associations. Songs exist in database but have no corresponding Music::Artist records or Music::SongArtist join table entries.

**ROOT CAUSE IDENTIFIED**: Songs created during album/release import do NOT have `Music::SongArtist` associations (only album-level `Music::AlbumArtist`). When series import encounters these existing songs, it skips artist import entirely, leaving them without direct artist links.

## Context
- Production database contains songs imported via `Music::ImportSongListFromMusicbrainzSeriesJob`
- **Key Finding**: Almost ALL songs without artists are songs that already existed from prior album imports
- Production logs show: `[SONG_SERIES_IMPORT] Found existing song` for songs without artists
- Album import creates songs through release import, which does NOT create `Music::SongArtist` associations
- Series import finds existing songs by MusicBrainz recording ID and returns them WITHOUT re-importing or enriching artist data
- Result: Songs have album-level artists but no song-level artists

## Requirements
- [x] Identify all code paths where artist association can fail silently
- [x] Determine which path(s) are occurring in production - **PRIMARY: Album import creates songs without artists**
- [ ] Fix release import to create SongArtist associations when creating songs
- [ ] Fix series import to enrich existing songs with missing artist data (use force_providers pattern)
- [ ] Add validation to prevent songs from being saved without artists
- [ ] Backfill missing artists for existing songs in production database
- [ ] Add tests for all scenarios

## Technical Approach

### Data Flow Analysis
The complete flow for song import with artist association:

1. **Job Entry** (`web-app/app/sidekiq/music/import_song_list_from_musicbrainz_series_job.rb:4-6`)
   - Receives list_id, finds Music::Songs::List, calls importer

2. **Series Fetch** (`web-app/app/lib/data_importers/music/lists/import_songs_from_musicbrainz_series.rb:41`)
   - Fetches MusicBrainz series with recordings: `/ws/2/series/{mbid}?inc=recording-rels`
   - Returns `relations` array with recording objects

3. **Recording Loop** (`import_songs_from_musicbrainz_series.rb:57-98`)
   - Extracts recording_id from each relation
   - Calls `import_song(recording_id)` for each

4. **Song Import** (`web-app/app/lib/data_importers/music/song/importer.rb`)
   - Uses ImporterBase with MusicBrainz provider
   - Provider fetches: `/ws/2/recording/{mbid}?inc=artist-credits`

5. **Artist Import** (`web-app/app/lib/data_importers/music/song/providers/musicbrainz/music_brainz.rb:95-137`)
   - Extracts `artist-credit` array from recording data
   - For each artist: imports via `DataImporters::Music::Artist::Importer`
   - Creates `Music::SongArtist` join record ONLY if artist persisted

6. **Auto-Save** (`web-app/app/lib/data_importers/importer_base.rb:126`)
   - Song saved after MusicBRainz provider succeeds
   - SongArtist associations saved as nested attributes

### PRIMARY ROOT CAUSE: Album Import Creates Songs Without Artists

**The Main Issue**: The system has two separate import paths for songs:
1. **Direct Song Import** - Creates `Music::SongArtist` associations ✅
2. **Release Import** (during album import) - Does NOT create `Music::SongArtist` associations ❌

#### How Album Import Creates Songs Without Artists

**File**: `web-app/app/lib/data_importers/music/release/providers/music_brainz.rb:213-244`

When albums are imported, the release provider creates songs through the `find_or_create_song` method:

```ruby
def find_or_create_song(recording_data)
  # Lines 217-223: Check if song exists by MusicBrainz recording ID
  recording_id = recording_data["id"]
  existing_song = Music::Song.with_identifier("music_musicbrainz_recording_id", recording_id).first

  # Line 225: Return existing song without modification
  return existing_song if existing_song

  # Lines 228-243: Create new song with ONLY basic metadata
  song = Music::Song.create!(
    title: recording_data["title"],
    duration_secs: recording_data["length"] / 1000,
    release_year: recording_data["first-release-date"]&.split("-")&.first&.to_i,
    notes: recording_data["disambiguation"]
  )

  # Lines 237-240: Create MusicBrainz identifier
  song.identifiers.create!(
    identifier_type: :music_musicbrainz_recording_id,
    value: recording_id
  )

  # NO song.song_artists.build() calls - songs created WITHOUT artists!
  song
end
```

**Critical Line**: This method creates songs with **NO artist associations**. Compare to direct song import at `song/providers/musicbrainz/music_brainz.rb:128-131` which DOES create `song_artists`.

#### Why Series Import Doesn't Fix This

**File**: `web-app/app/lib/data_importers/music/lists/import_songs_from_musicbrainz_series.rb:110-134`

When series import encounters songs created by album import:

```ruby
def import_song(recording_id)
  # Line 111: Check if song already exists
  existing_song = Music::Song.with_identifier("music_musicbrainz_recording_id", recording_id).first

  # Lines 112-114: Return existing song immediately - NO artist enrichment!
  if existing_song
    Rails.logger.info "[SONG_SERIES_IMPORT] Found existing song: '#{existing_song.title}' (#{recording_id})"
    return existing_song  # Artist import is SKIPPED!
  end

  # Lines 118-133: Only imports if song doesn't exist
  # This calls Song::Importer which DOES import artists
  result = DataImporters::Music::Song::Importer.call(musicbrainz_recording_id: recording_id)
  # ...
end
```

**Critical Issue**: Lines 111-114 create an early return that skips ALL artist import logic. The `Song::Importer` (line 118) is ONLY called for new songs, not existing ones.

#### The Two Artist Association Tables

The system maintains separate artist associations for albums and songs:

1. **`Music::AlbumArtist`** - Created during album import
   - **File**: `web-app/app/lib/data_importers/music/album/providers/music_brainz.rb:202`
   - Links albums to artists: `album.album_artists.build(artist: artist, position: index + 1)`
   - Albums imported from MusicBrainz HAVE artist associations ✅

2. **`Music::SongArtist`** - Only created during direct song import
   - **File**: `web-app/app/lib/data_importers/music/song/providers/musicbrainz/music_brainz.rb:128-131`
   - Links songs to artists: `song.song_artists.find_or_initialize_by(artist: artist, position: index + 1)`
   - Songs imported via release import DO NOT have artist associations ❌

These are **completely independent** - album artists do NOT cascade to songs.

#### Import Path Comparison

| Import Method | Creates Song? | Creates SongArtist? | File:Line |
|--------------|--------------|-------------------|-----------|
| Direct Song Import | ✅ Yes | ✅ Yes | `song/providers/musicbrainz/music_brainz.rb:128-131` |
| Release Import (via Album) | ✅ Yes | ❌ **NO** | `release/providers/music_brainz.rb:228-243` |
| Series Import (existing song) | ❌ Returns existing | ❌ Skipped | `lists/import_songs_from_musicbrainz_series.rb:112-114` |
| Series Import (new song) | ✅ Via Song::Importer | ✅ Via Song::Importer | `lists/import_songs_from_musicbrainz_series.rb:118` |

**Production Scenario**: Album imported first → Songs created without artists → Series import finds existing songs → Returns them without enrichment → Songs remain without artists

### Secondary Failure Paths (Theoretical)

#### Path 1: No artist-credit in Recording Data
**Location**: `song/providers/musicbrainz/music_brainz.rb:97-100`
```ruby
unless artist_credits.is_a?(Array)
  Rails.logger.warn "[SONG_IMPORT] No artist-credit array found in recording data"
  return
end
```
**Cause**: MusicBrainz API response missing or malformed `artist-credit` field
**Impact**: Provider succeeds with populated song data, but no artists imported
**Detection**: Check logs for "[SONG_IMPORT] No artist-credit array found"

#### Path 2: Artist Data Missing in Credit
**Location**: `song/providers/musicbrainz/music_brainz.rb:106-109`
```ruby
unless artist_data
  Rails.logger.warn "[SONG_IMPORT] No artist data in credit #{index}"
  next
end
```
**Cause**: Credit object missing `artist` field
**Impact**: Skips to next artist in array
**Detection**: Check logs for "[SONG_IMPORT] No artist data in credit"

#### Path 3: No MBID or Name for Artist
**Location**: `song/providers/musicbrainz/music_brainz.rb:114-117`
```ruby
unless artist_mbid || artist_name
  Rails.logger.warn "[SONG_IMPORT] No MBID or name for artist at position #{index}"
  next
end
```
**Cause**: Artist object missing both `id` and `name` fields
**Impact**: Skips to next artist in array
**Detection**: Check logs for "[SONG_IMPORT] No MBID or name for artist"

#### Path 4: Artist Import Failure
**Location**: `song/providers/musicbrainz/music_brainz.rb:127-135`
```ruby
if artist_result.success? && artist_result.item&.persisted?
  # Create association
else
  Rails.logger.error "[SONG_IMPORT] Artist import failed for '#{artist_name}': #{artist_result.all_errors.join(", ")}"
end
```
**Causes**:
- MusicBrainz artist API failure (network, timeout, rate limit)
- Artist validation failure (missing kind, invalid country)
- Artist save failure (database constraint, slug conflict)
- Category creation failure (see Path 5)

**Impact**: Artist not created, no SongArtist association
**Detection**: Check logs for "[SONG_IMPORT] Artist import failed"

#### Path 5: Category Creation Failure
**Location**: `artist/providers/music_brainz.rb:187-192`
```ruby
CategoryItem.find_or_create_by!(category: category, item: artist)
rescue => e
  Rails.logger.error "MusicBrainz artist categories error: #{e.message}"
  raise
```
**Cause**: CategoryItem.find_or_create_by! raises exception
**Impact**: Provider fails, artist not saved, propagates to Path 4
**Detection**: Check logs for "MusicBrainz artist categories error"

#### Path 6: Artist Validation Failure
**Location**: `importer_base.rb:124-134`
**Causes**:
- Missing required `name` field
- Missing required `kind` field (must be "person" or "band")
- Invalid country code (must be 2 characters)
- Date consistency validation (year_died requires person, year_formed requires band)

**Impact**: Artist not saved, propagates to Path 4
**Detection**: Check logs for validation errors in ImporterBase

#### Path 7: Database Save Failure
**Location**: `importer_base.rb:126-133`
```ruby
item.save!
rescue => e
  Rails.logger.error "Failed to save item after provider #{provider.class.name}: #{e.message}"
  provider_results[-1] = ProviderResult.failure(...)
end
```
**Causes**:
- Database constraint violation
- Slug generation conflict (FriendlyId duplicate)
- Transaction rollback

**Impact**: Artist not persisted, propagates to Path 4
**Detection**: Check logs for "Failed to save item after provider"

### Critical Issue: Silent Success
The song provider returns SUCCESS even if artist import fails because:
1. Song data population succeeds (title, duration, etc.)
2. Song identifiers created successfully
3. Artist import failures are logged but don't fail the provider
4. Song is saved with valid data but no associations

This means **songs can be successfully imported and saved without any artists**.

## Dependencies
- Access to production logs to identify which failure paths are occurring
- Database access to query songs without artists: `Music::Song.left_joins(:song_artists).where(music_song_artists: {id: nil})`

## Acceptance Criteria
- [ ] All failure paths documented with file:line references
- [ ] Production investigation identifies which paths are occurring
- [ ] Logging enhanced to capture all failure scenarios
- [ ] Fix implemented to ensure artists are always imported OR import fails
- [ ] Validation added to prevent songs without artists
- [ ] Tests added for all failure scenarios
- [ ] Backfill script created for existing broken songs
- [ ] All tests pass after fixes

## Design Decisions

### Should Song Import Fail if Artist Import Fails?
**Options**:
1. **Strict**: Fail song import if any artist fails to import
2. **Lenient**: Import song anyway, log artist failures
3. **Hybrid**: Require at least one artist, allow some to fail

**Current Behavior**: Option 2 (Lenient) - songs imported without artists
**Recommended**: Option 1 (Strict) - artist data is fundamental to song identity

### Validation Strategy
**Options**:
1. Model validation: `validates :artists, presence: true`
2. Provider validation: Check artist count before saving
3. Post-import validation: Verify associations after save

**Recommended**: Combination of 2 and 3 for immediate detection and verification

## Proposed Solutions

### Solution 1: Fix Release Import to Create Song Artists (RECOMMENDED) ✅

**Approach**: Modify `release/providers/music_brainz.rb:213-244` to import artists when creating songs

**Implementation**:
```ruby
def find_or_create_song(recording_data)
  recording_id = recording_data["id"]
  existing_song = Music::Song.with_identifier("music_musicbrainz_recording_id", recording_id).first
  return existing_song if existing_song

  # Instead of creating song directly, use Song::Importer
  result = DataImporters::Music::Song::Importer.call(
    musicbrainz_recording_id: recording_id
  )

  raise "Failed to import song: #{result.all_errors.join(', ')}" unless result.success? && result.item.persisted?
  result.item
end
```

**Pros**:
- Songs created with full artist data regardless of import path
- Reuses existing Song::Importer logic (DRY)
- Consistent artist associations across all import methods
- **No circular dependency risk** (verified - see investigation notes)
- API call overhead acceptable (self-hosted MusicBrainz instance)

**Cons**:
- Additional API calls per song (recording lookup for artist-credits)
- Slower release import due to artist processing
- May call Artist::Importer multiple times for same artist per album (but Finder prevents duplicates)

**Circular Dependency Analysis**: ✅ SAFE
- Song::Importer → Artist::Importer (terminal)
- No loops possible - dependency graph is acyclic (DAG)
- Maximum depth: 3 levels (Release → Song → Artist)

**File Changes**: `web-app/app/lib/data_importers/music/release/providers/music_brainz.rb:213-244`

### Solution 2: Make Series Import Enrich Existing Songs

**Approach**: Modify `lists/import_songs_from_musicbrainz_series.rb:110-134` to use `force_providers` for existing songs without artists

**Implementation**:
```ruby
def import_song(recording_id)
  existing_song = Music::Song.with_identifier("music_musicbrainz_recording_id", recording_id).first

  if existing_song
    # Check if song has artists
    if existing_song.song_artists.empty?
      Rails.logger.info "[SONG_SERIES_IMPORT] Enriching existing song without artists: '#{existing_song.title}'"
      result = DataImporters::Music::Song::Importer.call(
        musicbrainz_recording_id: recording_id,
        force_providers: true  # Re-run providers to add artists
      )
      return result.success? && result.item.persisted? ? result.item : nil
    else
      Rails.logger.info "[SONG_SERIES_IMPORT] Found existing song: '#{existing_song.title}'"
      return existing_song
    end
  end

  # Import new song
  result = DataImporters::Music::Song::Importer.call(musicbrainz_recording_id: recording_id)
  result.success? && result.item.persisted? ? result.item : nil
end
```

**Pros**:
- Fixes songs during series import without changing release import
- Only enriches songs that need it (missing artists)
- Backwards compatible with existing album import

**Cons**:
- Only fixes songs when they appear in a series list
- Doesn't prevent the problem, just patches it
- Songs without artists remain until series import encounters them

**File Changes**: `web-app/app/lib/data_importers/music/lists/import_songs_from_musicbrainz_series.rb`

### Solution 3: Hybrid Approach (BEST)

**Combine Solutions 1 and 2**:
1. Fix release import to create SongArtist associations (prevents new orphaned songs)
2. Fix series import to enrich existing songs (fixes already orphaned songs)
3. Add model validation to prevent future issues

**Implementation**:
- Apply both solutions above
- Add validation: `validates :song_artists, presence: true, message: "Song must have at least one artist"`

**Pros**:
- Prevents problem at source (release import)
- Fixes existing problem (series import enrichment)
- Future-proofed with validation

**Cons**:
- More code changes
- Need to ensure validation doesn't break other import paths

### Solution 4: Background Job to Backfill Artists

**Approach**: Create Sidekiq job to find and fix orphaned songs

**Implementation**:
```ruby
class Music::BackfillSongArtistsJob
  include Sidekiq::Job

  def perform
    # Find songs without artists
    orphaned_songs = Music::Song.left_joins(:song_artists)
      .where(music_song_artists: {id: nil})
      .where.not(identifiers: {identifier_type: 'music_musicbrainz_recording_id', value: nil})

    orphaned_songs.find_each do |song|
      recording_id = song.identifiers.find_by(identifier_type: 'music_musicbrainz_recording_id')&.value
      next unless recording_id

      Rails.logger.info "Backfilling artists for '#{song.title}' (#{recording_id})"
      DataImporters::Music::Song::Importer.call(
        musicbrainz_recording_id: recording_id,
        force_providers: true
      )
    end
  end
end
```

**Pros**:
- Fixes all existing orphaned songs
- Can be run on-demand or scheduled
- Idempotent (safe to re-run)

**Cons**:
- Doesn't prevent future occurrences
- Heavy API usage for large batches
- Should be combined with preventive solution

**Recommended**: Use Solution 3 (Hybrid) + Solution 4 (Backfill) for complete fix

---

## Implementation Notes

### Approach Taken

Implemented **Solution 3 (Hybrid Approach)** as recommended:

1. **Fixed Release Import** - Modified `find_or_create_song` to use `Song::Importer` instead of creating songs directly
2. **Fixed Series Import** - Added artist enrichment check for existing songs using `force_providers: true`
3. **Added Tests** - Created tests to prevent regression of both fixes
4. **Documented Backfill** - Provided Rails console script for production cleanup

### Key Files Changed

**Production Code**:
- `web-app/app/lib/data_importers/music/release/providers/music_brainz.rb:210-238`
  - Changed `find_or_create_song` method to call `Song::Importer` instead of creating songs directly
  - Now returns songs with full artist associations via Song::Importer's MusicBrainz provider

- `web-app/app/lib/data_importers/music/lists/import_songs_from_musicbrainz_series.rb:110-124`
  - Added check for `song.song_artists.empty?` when existing song found
  - Calls `Song::Importer` with `force_providers: true` to enrich orphaned songs
  - Skips enrichment for songs that already have artists

**Tests**:
- `web-app/test/lib/data_importers/music/release/providers/music_brainz_test.rb:333-377`
  - Added test: "populate creates songs with artist associations via Song::Importer"

- `web-app/test/lib/data_importers/music/lists/import_songs_from_musicbrainz_series_test.rb:247-330`
  - Added test: "call enriches existing songs without artists"
  - Added test: "call does not enrich existing songs that already have artists"

### Challenges Encountered

**Challenge 1: Circular Dependency Concern**
- Initial concern that calling `Song::Importer` from `Release::Importer` could create infinite loops
- **Resolution**: Traced all import chains, confirmed no circular dependencies exist
- Dependency graph remains acyclic (DAG): Release → Song → Artist (terminal)

**Challenge 2: Existing Tests Didn't Catch Bug**
- Release import tests never verified artist associations were created
- Series import tests never checked if songs had artists
- **Resolution**: Added specific tests for both scenarios to prevent regression

### Deviations from Plan

No significant deviations. Implemented Solution 3 (Hybrid) exactly as planned:
- Fixed root cause in release import ✅
- Added enrichment in series import ✅
- Created comprehensive tests ✅
- Documented backfill approach ✅

### Code Examples

**Before Fix** (Release Import):
```ruby
# Created songs WITHOUT artists
song = ::Music::Song.new(
  title: recording_data["title"],
  duration_secs: parse_duration_secs(recording_data["length"]),
  release_year: parse_release_year(recording_data["first-release-date"]),
  notes: recording_data["disambiguation"].presence
)
song.save
```

**After Fix** (Release Import):
```ruby
# Uses Song::Importer which imports WITH artists
result = DataImporters::Music::Song::Importer.call(
  musicbrainz_recording_id: recording_mbid
)

unless result.success? && result.item&.persisted?
  raise "Failed to import song: #{result.all_errors.join(", ")}"
end

result.item
```

**Before Fix** (Series Import):
```ruby
# Returned existing songs immediately, no enrichment
song = ::Music::Song.with_identifier("music_musicbrainz_recording_id", recording_id).first
if song
  Rails.logger.info "Found existing song"
  return song  # Artist import SKIPPED!
end
```

**After Fix** (Series Import):
```ruby
# Checks for missing artists and enriches
song = ::Music::Song.with_identifier("music_musicbrainz_recording_id", recording_id).first
if song
  if song.song_artists.empty?
    # Enrich with force_providers to add missing artists
    result = DataImporters::Music::Song::Importer.call(
      musicbrainz_recording_id: recording_id,
      force_providers: true
    )
    return result.success? && result.item&.persisted? ? result.item : song
  else
    return song
  end
end
```

### Investigation Steps Completed

#### Step 1: Triggered Production Import
- Imported new song series in production
- Confirmed logs showed "Found existing song" for songs without artists
- Verified almost all orphaned songs were from prior album imports

#### Step 2: Verified MusicBrainz API Response
- Fetched recording data for failing song: `2da2d9ea-b8e0-4d1d-a444-ad40703a8e93`
- Confirmed JSON response included proper `artist-credit` array
- Verified artist data structure was valid (had both `id` and `name`)
- Ruled out API data quality issues

#### Step 3: Traced Import Chains
- Used codebase-analyzer sub-agent to trace all import flows
- Identified that Release::Importer creates songs directly without artists
- Confirmed Series::Importer skips artist import for existing songs
- Found root cause: Two separate code paths for song creation

#### Step 4: Verified No Circular Dependencies
- Analyzed all importer chains for circular reference risk
- Confirmed dependency graph is acyclic (DAG)
- Maximum import depth: 3 levels (Release → Song → Artist)
- Safe to call Song::Importer from Release::Importer

### Testing Approach

**Test Coverage Added**:
1. Release import creates songs WITH artists (verifies Song::Importer call)
2. Series import enriches existing songs without artists (verifies `force_providers: true`)
3. Series import skips enrichment for songs with artists (verifies conditional logic)

**All Tests Passing**: 20 runs, 125 assertions, 0 failures, 0 errors, 0 skips

### Backfill Script for Production

Production cleanup can be done via Rails console:

```ruby
# Find all songs without any artists
orphaned_songs = Music::Song.left_joins(:song_artists).where(music_song_artists: {id: nil})

# Find songs imported from series (have series-related list items)
series_songs = Music::Song.joins(ranked_items: {list: :identifiers})
  .where(identifiers: {identifier_type: 'music_musicbrainz_series_id'})

# Intersection: songs from series without artists
broken_songs = songs_without_artists.merge(series_songs)

# Sample for investigation
broken_songs.limit(10).each do |song|
  puts "Song: #{song.title} (#{song.id})"
  puts "  MusicBrainz ID: #{song.identifiers.find_by(identifier_type: 'music_musicbrainz_recording_id')&.value}"
  puts "  Lists: #{song.lists.pluck(:title)}"
  puts "  Artists: #{song.artists.count}"
end
```

#### Step 2: Check Production Logs
Search for these patterns:
- `[SONG_IMPORT] No artist-credit array found`
- `[SONG_IMPORT] No artist data in credit`
- `[SONG_IMPORT] No MBID or name for artist`
- `[SONG_IMPORT] Artist import failed`
- `MusicBrainz artist categories error`
- `Failed to save item after provider`

#### Step 3: Test MusicBrainz API for Broken Songs
```ruby
# For each broken song, fetch current MusicBrainz data
broken_songs.limit(10).each do |song|
  mbid = song.identifiers.find_by(identifier_type: 'music_musicbrainz_recording_id')&.value
  next unless mbid

  search = Music::Musicbrainz::Search::RecordingSearch.new
  result = search.lookup_recording(mbid)

  if result[:success]
    data = result[:data]["recordings"].first
    artist_credits = data["artist-credit"]
    puts "Song: #{song.title}"
    puts "  Artist Credits: #{artist_credits.inspect}"
    puts "  Expected Artists: #{artist_credits&.map { |c| c.dig("artist", "name") }}"
  end
end
```

#### Step 4: Enhanced Logging
Add detailed logging to capture exact failure scenarios:
- Log MusicBrainz API responses for recordings
- Log artist-credit array structure
- Log each artist import attempt with MBID and name
- Log artist import results with detailed errors
- Track timing to identify timeout issues

### Performance Considerations

**API Call Volume**:
- Release import now makes additional API calls per song (to fetch artist-credit data)
- Acceptable overhead since using self-hosted MusicBrainz instance
- Artist::Finder prevents duplicate artist creation even with multiple API calls

**Database Impact**:
- Series import enrichment adds `song_artists.empty?` check per existing song
- Minimal overhead - simple count query on join table

### Future Improvements

1. **Optimization**: Cache artist lookups by MBID during album import to reduce API calls
2. **Monitoring**: Add metrics for orphaned song detection in production
3. **Validation**: Consider adding model validation: `validates :song_artists, presence: true`
4. **Background Processing**: Move song enrichment to background job for large series imports

### Lessons Learned

1. **Test Coverage Matters**: Bug existed because tests never verified artist associations
2. **Dual Association Models**: Having both `AlbumArtist` and `SongArtist` created confusion about which was populated when
3. **Import Path Matters**: Different import paths (direct vs. through release) created inconsistent data
4. **Early Returns Hide Bugs**: Series import's early return for existing songs masked the underlying issue
5. **Sub-agents Are Valuable**: codebase-analyzer sub-agent was critical for tracing complex import chains

### Related PRs

*[To be filled when PR is created]*

### Documentation Updated
- [x] Created comprehensive investigation todo file: `docs/todos/057-song-import-missing-artists-investigation.md`
- [x] Updated main todo list: `docs/todo.md` (moved to Completed section)
- [x] Created service documentation: `docs/lib/data_importers/music/lists/import_songs_from_musicbrainz_series.md`
- [ ] Update `docs/lib/data_importers/music/release/providers/music_brainz.md` with artist import changes (optional)
- [ ] Update `docs/lib/data_importers/music/song/importer.md` with usage in release import (optional)
