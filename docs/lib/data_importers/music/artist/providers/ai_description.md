# DataImporters::Music::Artist::Providers::AiDescription

## Summary
Asynchronous provider that queues AI-generated artist descriptions via background job. This provider validates required data and item persistence before queuing the job to prevent crashes from nil IDs.

## Associations
- Uses `::Music::Artist` model (no direct associations inside provider)
- Queues `::Music::ArtistDescriptionJob` for background processing

## Public Methods

### `#populate(artist, query:)`
Validates artist data and queues AI description generation job
- Parameters:
  - `artist` (Music::Artist) — Target artist for AI description
  - `query` (ImportQuery) — Query object (can be nil for item-based imports)
- Returns: ProviderResult with success status and data_populated
- Side effects: Queues `Music::ArtistDescriptionJob.perform_async(artist.id)`

## Validations
- **Artist name**: Must be present and non-blank
- **Artist persistence**: Must be persisted (saved to database) before queuing job

## Scopes
- None

## Constants
- None

## Callbacks
- None

## Dependencies
- `::Music::ArtistDescriptionJob` — Background job for AI description generation
- `DataImporters::ProviderBase` — Parent class providing result methods

## Async Provider Pattern
This provider follows the async provider pattern:
1. **Immediate validation** of required data and persistence
2. **Background job queuing** with persisted item ID
3. **Success result** returned immediately (actual work happens in background)
4. **Failure prevention** through persistence validation

## Error Handling
- **Missing name**: Returns failure with "Artist name required for AI description"
- **Not persisted**: Returns failure with "Artist must be persisted before queuing AI description job"
- **Provider exceptions**: Caught and returned as failure results

### Critical Persistence Validation
The persistence validation prevents a critical issue where:
1. Preceding providers (MusicBrainz) fail
2. Artist is not saved (ImporterBase only saves after successful providers)
3. AI Description provider queues job with `artist.id` (which is `nil`)
4. Background job crashes with `ActiveRecord::RecordNotFound`

## Usage Examples

### Successful Queuing
```ruby
# Artist must be persisted and have required data
artist = Music::Artist.create!(name: "Test Artist")

provider = DataImporters::Music::Artist::Providers::AiDescription.new
result = provider.populate(artist, query: query)

if result.success?
  puts "AI description job queued"
  puts result.data_populated # => [:ai_description_queued]
end
```

### Validation Failures
```ruby
# Non-persisted artist will fail
artist = Music::Artist.new(name: "Test Artist")
result = provider.populate(artist, query: query)
# => failure: "Artist must be persisted before queuing AI description job"

# Artist without name will fail
artist = Music::Artist.create!(name: "")
result = provider.populate(artist, query: query)
# => failure: "Artist name required for AI description"
```

## Testing
Comprehensive test coverage in `test/lib/data_importers/music/artist/providers/ai_description_test.rb`:
- **Success scenarios**: Proper job queuing with persisted artists
- **Validation failures**: Name and persistence requirements
- **Item-based imports**: Works with nil query parameter
- **Job stubbing**: Uses Mocha to verify job queuing without real execution

## Related Classes
- `DataImporters::Music::Album::Providers::AiDescription` — Similar provider for albums
- `DataImporters::Music::Album::Providers::Amazon` — Another async provider with same validation pattern
- `Services::Ai::Tasks::ArtistDescriptionTask` — The actual AI task executed by the background job