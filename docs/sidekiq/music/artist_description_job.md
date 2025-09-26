# Music::ArtistDescriptionJob

## Summary
Sidekiq background job that executes AI description generation for music artists. Part of the Music namespace for organized job processing.

## Associations
- Processes `Music::Artist` models
- Executes `Services::Ai::Tasks::ArtistDescriptionTask`

## Public Methods

### `#perform(artist_id)`
Executes the artist description generation task
- Parameters: artist_id (Integer) - ID of the artist to process
- Returns: void
- Side effects: Updates artist description, logs success/failure

## Job Configuration
- Queue: default Sidekiq queue
- Namespace: Music module
- Generated using: `bin/rails generate sidekiq:job Music::ArtistDescription`

## Error Handling
- Logs successful description generation with artist name and ID
- Logs failures with artist name, ID, and error message
- Does not retry on failure (relies on manual re-triggering)

## Dependencies
- Sidekiq gem for background job processing
- Services::Ai::Tasks::ArtistDescriptionTask for AI processing
- Music::Artist model for data retrieval
- Rails.logger for operation logging

## Usage Pattern
```ruby
# Queue job for immediate processing
Music::ArtistDescriptionJob.perform_async(artist.id)

# Used by DataImporter providers and AVO actions
```

## Integration Points
- Called by `DataImporters::Music::Artist::Providers::AiDescription`
- Triggered by `Avo::Actions::Music::GenerateArtistDescription`
- Can be queued manually from Rails console or admin interface
