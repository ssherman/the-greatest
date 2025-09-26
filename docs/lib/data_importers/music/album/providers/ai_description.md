# DataImporters::Music::Album::Providers::AiDescription

## Summary
DataImporter provider that queues AI description generation for music albums. Follows the async provider pattern to enable background processing without blocking the import flow.

## Associations
- Inherits from `DataImporters::ProviderBase`
- Works with `Music::Album` models
- Queues `Music::AlbumDescriptionJob` for processing

## Public Methods

### `#populate(album, query:)`
Queues AI description generation job for the album
- Parameters: 
  - album (Music::Album) - The album to generate description for
  - query (Hash) - Import query context (not used for AI descriptions)
- Returns: ProviderResult with success status and data_populated
- Side effects: Queues Sidekiq job for background processing

## Provider Configuration
- Provider name: "AiDescription"
- Data populated: `[:ai_description_queued]`
- Async pattern: Returns success immediately after queuing job

## Dependencies
- Music::AlbumDescriptionJob for background processing
- DataImporters::ProviderBase for common functionality
- Sidekiq for job queuing

## Usage Pattern
```ruby
# Used automatically by Album importer
DataImporters::Music::Album::Importer.call(title: "Dark Side of the Moon")

# Can be used with force_providers for re-enrichment
DataImporters::Music::Album::Importer.call(
  title: "Dark Side of the Moon", 
  force_providers: true
)
```

## Integration Points
- Included in `DataImporters::Music::Album::Importer` provider list
- Executes independently of MusicBrainz providers
- Enables background AI enrichment during import process

## Design Pattern
Follows the async provider pattern established by Amazon provider:
1. Validates required data exists
2. Queues background job immediately
3. Returns success with queued status
4. Background job handles actual AI processing
