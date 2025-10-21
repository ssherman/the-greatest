# DataImporters::Music::Lists::ImportSongsFromMusicbrainzSeries

## Summary
Service for importing song lists from MusicBrainz series entities. Fetches all recordings in a series and creates songs with full artist associations, then adds them to a Music::Songs::List. **Updated 2025-10-21**: Now enriches existing songs that lack artist associations.

## Inheritance
Inherits from `ApplicationService`

## Public Methods

### `.call(list:)`
Imports all songs from a MusicBrainz series and adds them to the specified list.
- Parameters:
  - `list` (Music::Songs::List): The target list (must have `musicbrainz_series_id`)
- Returns: Hash with `:success`, `:message`, `:imported_count`, `:total_count`
- Side Effects: Creates Music::Song records, Music::SongArtist associations, and RankedItem list entries

## Implementation Details

### Validation
- Raises `ArgumentError` if `list.musicbrainz_series_id` is blank
- Raises `ArgumentError` if list is not a `Music::Songs::List` instance
- Returns failure hash if series data fetch fails

### Import Flow

1. **Fetch Series Data** (`import_songs_from_musicbrainz_series.rb:39-48`)
   - Calls `Music::Musicbrainz::Search::SeriesSearch#browse_series_with_recordings`
   - API endpoint: `/ws/2/series/{mbid}?inc=recording-rels&fmt=json`
   - Returns nil if fetch fails or no data

2. **Extract Recordings** (`import_songs_from_musicbrainz_series.rb:105-108`)
   - Filters relations array for `target-type: "recording"`
   - Extracts recording ID, title, and position number
   - Skips recordings without valid MusicBrainz IDs

3. **Import Each Song** (`import_songs_from_musicbrainz_series.rb:110-134`)
   - Checks if song exists by MusicBrainz recording ID
   - **NEW (2025-10-21)**: If song exists but has no artists, enriches with `force_providers: true`
   - If song doesn't exist, calls `DataImporters::Music::Song::Importer` to create with full data
   - Handles import failures gracefully, logs errors, continues to next song

4. **Create List Items** (`import_songs_from_musicbrainz_series.rb:136-153`)
   - Creates `RankedItem` records linking songs to list
   - Preserves series position order
   - Skips if song already in list

### Artist Association Behavior

**For New Songs**:
- Calls `DataImporters::Music::Song::Importer.call(musicbrainz_recording_id: recording_id)`
- Song::Importer fetches recording with `inc=artist-credits`
- Creates `Music::Artist` records via `DataImporters::Music::Artist::Importer`
- Creates `Music::SongArtist` join records with position ordering

**For Existing Songs Without Artists** (Added 2025-10-21):
```ruby
if song.song_artists.empty?
  result = DataImporters::Music::Song::Importer.call(
    musicbrainz_recording_id: recording_id,
    force_providers: true  # Re-runs providers to add missing artists
  )
end
```

**For Existing Songs With Artists**:
- Returns song immediately without re-import
- No unnecessary API calls made

## Usage Patterns

### Typical Usage (from Sidekiq Job)
```ruby
list = Music::Songs::List.find(list_id)
list.update!(musicbrainz_series_id: "b3484a66-a4de-444d-93d3-c99a73656905")

result = DataImporters::Music::Lists::ImportSongsFromMusicbrainzSeries.call(list: list)

if result[:success]
  puts "Imported #{result[:imported_count]} of #{result[:total_count]} songs"
else
  puts "Import failed: #{result[:message]}"
end
```

### From Avo Admin Action
```ruby
# app/avo/actions/lists/import_from_musicbrainz_series.rb
Music::ImportSongListFromMusicbrainzSeriesJob.perform_async(record.id)
```

## Return Values

### Success Response
```ruby
{
  success: true,
  message: "Imported 50 of 50 songs",
  imported_count: 50,
  total_count: 50,
  list: Music::Songs::List instance
}
```

### Failure Response
```ruby
{
  success: false,
  message: "List must have musicbrainz_series_id",
  imported_count: 0,
  total_count: 0
}
```

### Partial Success
```ruby
{
  success: true,
  message: "Imported 45 of 50 songs",
  imported_count: 45,  # Some songs failed to import
  total_count: 50
}
```

## Error Handling

### Validation Errors
- Missing `musicbrainz_series_id`: Returns `{success: false, message: "List must have musicbrainz_series_id"}`
- Wrong list type: Returns `{success: false, message: "List must be a Music::Songs::List"}`

### Import Errors
- Series fetch failure: Returns `{success: false, message: "Failed to fetch series data"}`
- Individual song import failures: Logged but don't halt entire import
- Creates list items only for successfully imported songs

### Logging

**Info Level**:
- `[SONG_SERIES_IMPORT] Found existing song: 'Title' (mbid)` - Song exists with artists
- `[SONG_SERIES_IMPORT] Found existing song without artists, enriching: 'Title' (mbid)` - Enriching orphaned song
- `[SONG_SERIES_IMPORT] Calling Song::Importer for mbid` - Importing new song
- `[SONG_SERIES_IMPORT] Song::Importer SUCCESS for mbid` - Song imported successfully

**Error Level**:
- `[SONG_SERIES_IMPORT] Song::Importer FAILED for mbid` - Song import failed
- `[SONG_SERIES_IMPORT] Song has no ID (not saved)` - Song failed validation

## Dependencies

### External Services
- `Music::Musicbrainz::Search::SeriesSearch` - Fetches series with recordings from MusicBrainz API
- `DataImporters::Music::Song::Importer` - Creates/enriches songs with full data including artists
- `DataImporters::Music::Artist::Importer` - Called indirectly via Song::Importer

### Models
- `Music::Songs::List` - Target list for imported songs
- `Music::Song` - Created or enriched during import
- `Music::Artist` - Created via Song::Importer's artist import
- `Music::SongArtist` - Join table created for artist associations
- `RankedItem` - Created to link songs to list with position

## Performance Considerations

### API Calls
- 1 API call to fetch series with recordings
- 1 API call per new song (to fetch recording with artist-credits)
- 1 API call per artist per song (to fetch artist details)
- Artist::Finder prevents duplicate artist creation

### Database Queries
- Efficient identifier-based lookups for existing songs
- Bulk song creation avoided (songs imported one at a time for error isolation)
- `song_artists.empty?` check adds minimal overhead (simple count query)

### Optimizations
- Existing songs with artists skipped (no API calls)
- Existing songs without artists enriched only when needed
- Failed song imports don't halt entire series import

## Related Classes
- `Music::ImportSongListFromMusicbrainzSeriesJob` - Sidekiq job that calls this service
- `DataImporters::Music::Lists::ImportFromMusicbrainzSeries` - Equivalent for album series
- `DataImporters::Music::Song::Importer` - Direct song import service
- `Music::Musicbrainz::Search::SeriesSearch` - Series API wrapper

## Version History
- **2025-10-21**: Added artist enrichment for existing songs without artists (bug fix #057)
- **2025-10-03**: Initial implementation for song series import feature (task #044)

## Known Issues
None currently.

## Testing
Test file: `test/lib/data_importers/music/lists/import_songs_from_musicbrainz_series_test.rb`

Key test scenarios:
- Successfully imports songs from series
- Handles series search failures
- Handles individual song import failures gracefully
- Skips existing songs in list
- Validates list has musicbrainz_series_id
- Validates list is correct type
- **NEW**: Enriches existing songs without artists
- **NEW**: Does not re-import songs that already have artists
