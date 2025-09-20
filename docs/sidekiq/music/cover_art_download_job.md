# Music::CoverArtDownloadJob

## Summary
Background job for downloading album cover art from MusicBrainz Cover Art Archive. Provides high-quality album artwork for Music::Album records that have MusicBrainz identifiers but lack primary images.

## Queue Configuration
- **Queue**: `:serial`
- **Concurrency**: 1 (configured via Sidekiq capsule)
- **Purpose**: Prevents overwhelming Cover Art Archive API and manages download bandwidth

## Public Methods

### `#perform(album_id)`
Main job execution method
- Parameters:
  - `album_id` (Integer) - ID of Music::Album to download cover art for
- Side Effects: Creates Image record with primary cover art
- Graceful Handling: Skips processing if conditions not met (logs but doesn't fail)

## Workflow
1. **Load Album**: Finds Music::Album by ID
2. **Image Check**: Skips if album already has primary image
3. **MusicBrainz Lookup**: Finds release group ID from identifiers
4. **Cover Art Download**: Downloads from Cover Art Archive using MusicBrainz ID
5. **Image Creation**: Creates Image record with downloaded artwork

## Skip Conditions
- Album already has a primary image (avoids overwriting existing artwork)
- Album lacks MusicBrainz release group identifier (no source to download from)
- Cover art not available (404 or other HTTP errors handled gracefully)

## Cover Art Archive Integration
- **URL Pattern**: `https://coverartarchive.org/release-group/{musicbrainz_id}/front`
- **Image Quality**: Front cover artwork in original resolution
- **Fallback**: Gracefully handles missing artwork (common for obscure releases)

## Dependencies
- `Music::Album` model - Target for cover art
- `Down` gem - HTTP download library
- `Image` model - Storage for downloaded artwork
- Active Storage - File attachment system
- MusicBrainz identifiers - Source of release group IDs

## Error Handling
- **Missing Images**: Logs informational message, doesn't fail job
- **Network Errors**: Caught and logged, job continues gracefully
- **File Cleanup**: Ensures temporary files are removed even on errors
- **Validation Errors**: Uses build/attach/save pattern to avoid Active Storage issues

## File Management
```ruby
# Safe file handling pattern
begin
  tempfile = Down.download(cover_art_url)
  # ... process file ...
ensure
  tempfile&.close
  tempfile&.unlink
end
```

## Image Creation
- Creates Image with `primary: true` flag
- Uses parameterized album title for filename
- Assumes JPEG format (standard for Cover Art Archive)
- Integrates with Active Storage for cloud storage

## Integration Points
- **Triggered by**: `DataImporters::Music::Album::Providers::MusicBrainz`
- **Requires**: MusicBrainz release group identifier
- **Complements**: Amazon image downloads (provides fallback/alternative source)

## Logging
- Start/completion messages with album titles
- Skip reasons clearly documented
- Error conditions logged as informational (not failures)
- Download success confirmations

## Performance Considerations
- Serial processing prevents bandwidth overload
- Skip logic avoids unnecessary downloads
- Graceful error handling prevents job failures
- Temporary file cleanup prevents disk space issues

## Data Quality
- MusicBrainz Cover Art Archive provides high-quality, official artwork
- Front cover images typically higher resolution than Amazon thumbnails
- Community-curated for accuracy and completeness
- Free access without API rate limits (but respects serial processing)

## Operational Notes
- Jobs triggered automatically during MusicBrainz album imports
- Many albums may not have cover art available (this is normal)
- Download failures are informational, not operational issues
- Serial queue prevents overwhelming the Cover Art Archive