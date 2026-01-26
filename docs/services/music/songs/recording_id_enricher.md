# Services::Music::Songs::RecordingIdEnricher

## Summary

Enriches a song with additional MusicBrainz recording IDs by searching for all recordings matching the song's title and artist, then using AI to filter for exact matches (same version, not remixes/remasters/covers).

## Usage

```ruby
# Enrich a song with additional recording IDs
result = Services::Music::Songs::RecordingIdEnricher.call(
  song: song,
  dry_run: false
)

# Check result
if result.success?
  puts "Found #{result.data[:candidates_found]} candidates"
  puts "#{result.data[:exact_matches]} exact matches"
  puts "Created #{result.data[:new_identifiers_created]} new identifiers"
end
```

## Public Methods

### `.call(song:, dry_run: false)`

Enriches the given song with MusicBrainz recording IDs.

**Parameters:**
- `song` (Music::Song) - The song to enrich
- `dry_run` (Boolean) - If true, reports what would be created without making changes

**Returns:** `Result` struct with:
- `success?` (Boolean) - Whether the operation succeeded
- `data` (Hash) - Contains:
  - `candidates_found` (Integer) - Number of MusicBrainz recordings found
  - `exact_matches` (Integer) - Number of recordings AI identified as exact matches
  - `new_identifiers_created` (Integer) - Number of new Identifier records created
  - `existing_identifiers` (Integer) - Number of identifiers that already existed
  - `reasoning` (String) - AI's explanation of filtering decisions
  - `skip_reason` (String) - Present if song was skipped (no artists, no candidates, etc.)
- `errors` (Array) - Error messages if operation failed

## Search Strategy

The enricher uses a two-tier search strategy for accuracy:

1. **Artist MBID Search (Preferred)**: If the song's primary artist has `music_musicbrainz_artist_id` identifiers, uses `search_by_artist_mbid_and_title` for precise matching
2. **Artist Name Search (Fallback)**: If no artist MBID exists, falls back to `search_by_artist_and_title` using the artist's name

When an artist has multiple MusicBrainz IDs, all are searched and results are deduplicated by recording ID.

## Constants

- `SEARCH_LIMIT` (50) - Maximum number of candidate recordings to retrieve from MusicBrainz

## Dependencies

- `Music::Musicbrainz::Search::RecordingSearch` - MusicBrainz API client
- `Services::Ai::Tasks::Music::Songs::RecordingMatcherTask` - AI task for filtering candidates
- `Identifier` model - For storing recording IDs

## Related

- `Services::Ai::Tasks::Music::Songs::RecordingMatcherTask` - AI task used for filtering
- `music:songs:enrich_recording_ids` rake task - CLI interface for batch processing
- `music:songs:backfill_release_years` rake task - Uses created identifiers to set release_year
