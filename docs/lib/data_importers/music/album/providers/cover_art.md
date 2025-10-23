# DataImporters::Music::Album::Providers::CoverArt

## Summary
Async provider that queues background jobs to download album cover art from the MusicBrainz Cover Art Archive. Part of the Music::Album data import pipeline.

## Purpose
Separates cover art downloading from metadata import, allowing the cover art provider to be:
- Extended with multiple sources (MusicBrainz, Spotify, Amazon Images)
- Managed independently from metadata providers
- Easily tested and maintained

## Provider Flow
1. Validates album is persisted (prevents nil ID errors)
2. Queues `Music::CoverArtDownloadJob` with album ID
3. Returns success immediately (actual download happens in background)

## Public Methods

### `#populate(album, query:)`
Queues cover art download job for the given album.

**Parameters:**
- `album` (Music::Album) - The album to download cover art for
- `query` (ImportQuery) - Import query object (not used by this provider, can be nil)

**Returns:**
- `ProviderResult` with `success: true` and `data_populated: [:cover_art_queued]` if successful
- `ProviderResult` with `success: false` and error message if album is not persisted

**Side Effects:**
- Enqueues `Music::CoverArtDownloadJob` to run in background

**Validations:**
- Album must be persisted before queuing job (prevents nil ID errors in production)

## Position in Provider Chain
Runs **after** MusicBrainz provider to ensure album metadata exists before downloading cover art:
1. MusicBrainz - imports metadata
2. **CoverArt** - downloads cover art
3. Amazon - enriches with product data
4. AiDescription - generates AI descriptions

## Dependencies
- `Music::CoverArtDownloadJob` - Background job that performs actual download
- `DataImporters::ProviderBase` - Base class providing result helpers

## Design Decisions

### Why a Separate Provider?
Originally, the MusicBrainz provider called the cover art job directly. This was refactored into a separate provider for:
- **Single Responsibility**: MusicBrainz handles metadata, CoverArt handles images
- **Extensibility**: Easy to add multiple cover art sources later
- **Testability**: Clear separation of concerns
- **Maintainability**: Cover art logic isolated in one place

### Why Validate Persistence?
The provider checks `album.persisted?` before queuing the job because:
- Albums are saved **after** each provider runs (incremental saving pattern)
- Queuing with a nil ID causes production errors
- Matches pattern used by other async providers (AiDescription, Amazon)

## Future Enhancements
The provider can be extended to support multiple cover art sources with fallback logic:

```ruby
def populate(album, query:)
  return failure_result(...) unless album.persisted?

  # Try multiple sources in priority order
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

## Related Documentation
- [Music::CoverArtDownloadJob](../../../../sidekiq/music/cover_art_download_job.md) - Background job implementation
- [DataImporters::Music::Album::Importer](../importer.md) - Album import orchestration
- [DataImporters::Music::Album::Providers::MusicBrainz](music_brainz.md) - Metadata provider
- [Task 059](../../../../../todos/059-fix-cover-art-job-nil-parameter-bug.md) - Implementation details and rationale
