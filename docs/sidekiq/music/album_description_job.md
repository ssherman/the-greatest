# Music::AlbumDescriptionJob

## Summary
Sidekiq background job that executes AI description generation for music albums. Part of the Music namespace for organized job processing.

## Associations
- Processes `Music::Album` models
- Executes `Services::Ai::Tasks::AlbumDescriptionTask`

## Public Methods

### `#perform(album_id)`
Executes the album description generation task
- Parameters: album_id (Integer) - ID of the album to process
- Returns: void
- Side effects: Updates album description, logs success/failure

## Job Configuration
- Queue: default Sidekiq queue
- Namespace: Music module
- Generated using: `bin/rails generate sidekiq:job Music::AlbumDescription`

## Error Handling
- Logs successful description generation with album title and ID
- Logs failures with album title, ID, and error message
- Does not retry on failure (relies on manual re-triggering)

## Dependencies
- Sidekiq gem for background job processing
- Services::Ai::Tasks::AlbumDescriptionTask for AI processing
- Music::Album model for data retrieval
- Rails.logger for operation logging

## Usage Pattern
```ruby
# Queue job for immediate processing
Music::AlbumDescriptionJob.perform_async(album.id)

# Used by DataImporter providers and AVO actions
```

## Integration Points
- Called by `DataImporters::Music::Album::Providers::AiDescription`
- Triggered by `Avo::Actions::Music::GenerateAlbumDescription`
- Can be queued manually from Rails console or admin interface
