# DataImporters::Music::Song::Providers::Musicbrainz::MusicBrainz

## Summary
Imports song data from MusicBrainz recordings and enriches it with identifiers, duration, release year, ISRC codes, and artist associations. Handles multi-artist songs with proper position ordering via `SongArtist` join table.

## Associations
- Uses `::Music::Song` model (target of population)
- Creates `::Identifier` records via `song.identifiers.find_or_initialize_by`
- Creates `::Music::SongArtist` records via `song.song_artists.find_or_initialize_by`
- Imports `::Music::Artist` records via `DataImporters::Music::Artist::Importer`

## Public Methods

### `#populate(song, query:)`
Populates a `::Music::Song` with MusicBrainz recording data
- Parameters:
  - `song` (Music::Song) — Target song to populate
  - `query` (ImportQuery) — Query with `musicbrainz_recording_id` or `title`
- Returns: Result (success, data_populated|errors)
- Side effects: Builds identifiers, creates artist associations, imports artists

## Validations
- Delegated to `::Music::Song` model
- **Critical**: Only creates `SongArtist` associations when artist is `.persisted?`
- Prevents orphaned associations with unpersisted artist records

## Scopes
- None

## Constants
- None

## Callbacks
- None

## Dependencies
- `::Music::Musicbrainz::Search::RecordingSearch` — recording search/lookup adapter
- `::DataImporters::Music::Artist::Importer` — imports associated artists
- `::Identifier` — stores external IDs (MusicBrainz recording ID, ISRC)
- `::Music::SongArtist` — join table for song-artist associations with position

## Error Handling
- **Network failures**: Return failure result with error details
- **Invalid API responses**: Return failure result with parsing errors
- **Empty search results**: Return success result with empty data (allows song creation with basic info)
- **Artist import failures**: Logged but don't fail song import (song data still valuable)
- **Unpersisted artists**: Skipped - no `SongArtist` created (prevents validation errors)
- **Provider exceptions**: Caught and returned as failure results

### Enhancement Philosophy
This provider operates as an **enhancement service** rather than a **validation gate**:
- "Not found in MusicBrainz" returns success with empty `data_populated`
- Allows songs not yet in the database to be created with basic user-provided information
- Artist import failures don't block song creation
- Enables graceful degradation when MusicBrainz is unavailable

## Data Mapping

### MusicBrainz Recording → Music::Song
- `title` → `song.title`
- `length` (milliseconds) → `song.duration_secs` (converted to seconds, rounded)
- `isrc` → `song.isrc` (also stored as identifier)
- `first-release-date` → `song.release_year` (extracts year, validates > 1900)
- `id` (MBID) → identifier (type: `music_musicbrainz_recording_id`)
- `artist-credit` (array) → `SongArtist` records with position (1-based index)

### Artist Credits Handling
- Iterates through `artist-credit` array (MusicBrainz format)
- Extracts artist MBID and name from each credit
- Imports each artist via `DataImporters::Music::Artist::Importer`
- Creates `SongArtist` with `position: index + 1` (1-based, not 0-based)
- **Only creates association if artist import succeeds AND artist is persisted**

## Private Methods

### `#search_for_recording(title)`
Wraps recording search by title

### `#lookup_recording_by_mbid(mbid)`
Wraps direct recording lookup by MusicBrainz ID

### `#search_service`
Memoized instance of `RecordingSearch`

### `#populate_song_data(song, recording_data)`
Maps core fields:
- title
- duration (ms → seconds)
- ISRC
- release year (from first-release-date)

### `#create_identifiers(song, recording_data)`
Builds identifiers:
- `music_musicbrainz_recording_id` (from recording `id`)
- `music_isrc` (from recording `isrc`)

Uses `find_or_initialize_by` to prevent duplicates

### `#import_artists(song, recording_data)`
Processes `artist-credit` array:
1. Validates `artist-credit` is an array
2. Iterates with index to maintain position
3. For each credit:
   - Extracts artist MBID and name
   - Imports artist via `DataImporters::Music::Artist::Importer`
   - **Critical**: Only creates `SongArtist` if artist import succeeded and `artist.persisted?`
   - Position is `index + 1` (1-based for database validation)
4. Logs success/failure for each artist

**Bug Fix Note**: Prior to 2025-10-05, this method created `SongArtist` records even when artist import failed or returned unpersisted artists, resulting in songs without artists. Fixed by adding `.persisted?` check.

### `#data_fields_populated(recording_data)`
Returns array of populated field symbols for logging:
- Always: `:title`, `:musicbrainz_recording_id`
- Conditional: `:duration`, `:isrc`, `:release_year`, `:artists`

## Logging
Uses `[SONG_IMPORT]` prefix for all log messages:
- Provider start (with MBID or title)
- API success/failure
- Empty recordings
- Processing recording title
- Song validation status (persisted?, valid?, errors)
- Song associations count (identifiers, song_artists)
- Artist import success/failure for each artist
- Provider success with fields populated
- Provider errors with backtrace

## Performance Considerations
- API calls: 1 per song (search or lookup)
- Artist imports: 1 per unique artist (cached via identifiers table)
- Database queries: Minimal due to `find_or_initialize_by` caching
- Logging: Comprehensive but performant (no N+1 queries)

## Common Issues

### Issue: Songs Created Without Artists
**Symptom**: Songs exist but `song.artists.count == 0`

**Cause**: Artist import returned unpersisted artist (validation failure)

**Solution**: Provider now checks `.persisted?` before creating `SongArtist` (fixed 2025-10-05)

**Detection Query**:
```ruby
Music::Song.left_joins(:song_artists).where(music_song_artists: { id: nil })
```

### Issue: 301 Redirects From MusicBrainz
**Symptom**: "Unexpected status: 301" errors

**Cause**: MusicBrainz redirects merged recording IDs, but HTTP client wasn't following redirects

**Solution**: Added `faraday-follow_redirects` middleware to `BaseClient` (fixed 2025-10-05)

## Example Usage

### Import by MusicBrainz Recording ID
```ruby
provider = DataImporters::Music::Song::Providers::Musicbrainz::MusicBrainz.new
song = Music::Song.new
query = DataImporters::Music::Song::ImportQuery.new(
  musicbrainz_recording_id: "6b9a9e04-abd7-4666-86ba-bb220ef4c3b2"
)

result = provider.populate(song, query: query)

if result.success?
  puts "Populated: #{result.data_populated.join(', ')}"
  puts "Artists: #{song.artists.map(&:name).join(', ')}"
else
  puts "Errors: #{result.errors.join(', ')}"
end
```

### Import by Title (Search)
```ruby
provider = DataImporters::Music::Song::Providers::Musicbrainz::MusicBrainz.new
song = Music::Song.new
query = DataImporters::Music::Song::ImportQuery.new(title: "Comfortably Numb")

result = provider.populate(song, query: query)
# Uses first search result (top match by score)
```

## Related Documentation
- [Music::Song Model](../../../../models/music/song.md)
- [Music::SongArtist Model](../../../../models/music/song_artist.md)
- [DataImporters::Music::Song::Importer](../importer.md)
- [DataImporters::Music::Artist::Importer](../../artist/importer.md)
- [RecordingSearch API](../../../../music/musicbrainz/search/recording_search.md)
- [Task 044: Import Song Lists](../../../../../todos/044-import-song-lists-by-series.md)
- [Task 046: Fix Missing Artists Bug](../../../../../todos/046-fix-song-import-missing-artists-bug.md)

## Testing
See `test/lib/data_importers/music/song/importer_test.rb` for comprehensive test coverage including:
- Single artist songs
- Multi-artist songs with position ordering
- ISRC identifier handling
- Artist import failures
- Unpersisted artist edge cases (critical bug fix test)
- Empty recordings handling
