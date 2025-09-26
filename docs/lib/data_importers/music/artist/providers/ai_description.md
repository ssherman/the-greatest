# DataImporters::Music::Artist::Providers::AiDescription

## Summary
DataImporter provider that queues AI description generation for music artists. Follows the async provider pattern to enable background processing without blocking the import flow.

## Associations
- Inherits from `DataImporters::ProviderBase`
- Works with `Music::Artist` models
- Queues `Music::ArtistDescriptionJob` for processing

## Public Methods

### `#populate(artist, query:)`
Queues AI description generation job for the artist
- Parameters: 
  - artist (Music::Artist) - The artist to generate description for
  - query (Hash) - Import query context (not used for AI descriptions)
- Returns: ProviderResult with success status and data_populated
- Side effects: Queues Sidekiq job for background processing

## Provider Configuration
- Provider name: "AiDescription"
- Data populated: `[:ai_description_queued]`
- Async pattern: Returns success immediately after queuing job

## Dependencies
- Music::ArtistDescriptionJob for background processing
- DataImporters::ProviderBase for common functionality
- Sidekiq for job queuing

## Usage Pattern
```ruby
# Used automatically by Artist importer
DataImporters::Music::Artist::Importer.call(name: "Pink Floyd")

# Can be used with force_providers for re-enrichment
DataImporters::Music::Artist::Importer.call(
  name: "Pink Floyd", 
  force_providers: true
)
```

## Integration Points
- Included in `DataImporters::Music::Artist::Importer` provider list
- Executes independently of MusicBrainz providers
- Enables background AI enrichment during import process

## Design Pattern
Follows the async provider pattern established by Amazon provider:
1. Validates required data exists
2. Queues background job immediately
3. Returns success with queued status
4. Background job handles actual AI processing
