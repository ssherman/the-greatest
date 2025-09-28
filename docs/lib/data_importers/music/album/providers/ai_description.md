# DataImporters::Music::Album::Providers::AiDescription

## Summary
Asynchronous provider that queues AI-generated album descriptions via background job. This provider validates required data and item persistence before queuing the job to prevent crashes from nil IDs.

## Associations
- Uses `::Music::Album` model (no direct associations inside provider)
- Queues `::Music::AlbumDescriptionJob` for background processing

## Public Methods

### `#populate(album, query:)`
Validates album data and queues AI description generation job
- Parameters:
  - `album` (Music::Album) — Target album for AI description
  - `query` (ImportQuery) — Query object (can be nil for item-based imports)
- Returns: ProviderResult with success status and data_populated
- Side effects: Queues `Music::AlbumDescriptionJob.perform_async(album.id)`

## Validations
- **Album title**: Must be present and non-blank
- **Album artists**: Must have at least one associated artist
- **Album persistence**: Must be persisted (saved to database) before queuing job

## Scopes
- None

## Constants
- None

## Callbacks
- None

## Dependencies
- `::Music::AlbumDescriptionJob` — Background job for AI description generation
- `DataImporters::ProviderBase` — Parent class providing result methods

## Async Provider Pattern
This provider follows the async provider pattern:
1. **Immediate validation** of required data and persistence
2. **Background job queuing** with persisted item ID
3. **Success result** returned immediately (actual work happens in background)
4. **Failure prevention** through persistence validation

## Error Handling
- **Missing title**: Returns failure with "Album title required for AI description"
- **No artists**: Returns failure with "Album must have at least one artist for AI description"
- **Not persisted**: Returns failure with "Album must be persisted before queuing AI description job"
- **Provider exceptions**: Caught and returned as failure results

### Critical Persistence Validation
The persistence validation prevents a critical issue where:
1. Preceding providers (MusicBrainz, Amazon) fail
2. Album is not saved (ImporterBase only saves after successful providers)
3. AI Description provider queues job with `album.id` (which is `nil`)
4. Background job crashes with `ActiveRecord::RecordNotFound`

## Usage Examples

### Successful Queuing
```ruby
# Album must be persisted and have required data
album = Music::Album.create!(title: "Test Album")
album.album_artists.create!(artist: artist, position: 1)

provider = DataImporters::Music::Album::Providers::AiDescription.new
result = provider.populate(album, query: query)

if result.success?
  puts "AI description job queued"
  puts result.data_populated # => [:ai_description_queued]
end
```

### Validation Failures
```ruby
# Non-persisted album will fail
album = Music::Album.new(title: "Test Album")
result = provider.populate(album, query: query)
# => failure: "Album must be persisted before queuing AI description job"

# Album without title will fail
album = Music::Album.create!(title: "")
result = provider.populate(album, query: query)
# => failure: "Album title required for AI description"
```

## Testing
Comprehensive test coverage in `test/lib/data_importers/music/album/providers/ai_description_test.rb`:
- **Success scenarios**: Proper job queuing with persisted albums
- **Validation failures**: Title, artists, and persistence requirements
- **Item-based imports**: Works with nil query parameter
- **Job stubbing**: Uses Mocha to verify job queuing without real execution

## Related Classes
- `DataImporters::Music::Artist::Providers::AiDescription` — Similar provider for artists
- `DataImporters::Music::Album::Providers::Amazon` — Another async provider with same validation pattern
- `Services::Ai::Tasks::AlbumDescriptionTask` — The actual AI task executed by the background job