# ImportListFromMusicbrainzSeriesJob

## Summary
Background job that imports albums from a MusicBrainz series into a Music::Albums::List. Provides asynchronous processing for potentially long-running import operations triggered from the admin interface.

## Queue
Uses the default Sidekiq queue.

## Usage

### Enqueue Job
```ruby
ImportListFromMusicbrainzSeriesJob.perform_async(list_id)
```

### Parameters
- `list_id` (Integer) - The ID of the Music::Albums::List to import albums into

## Process
1. Finds the Music::Albums::List by ID
2. Delegates to `DataImporters::Music::Lists::ImportFromMusicbrainzSeries.call`
3. Returns the result hash from the import service

## Error Handling
- Will raise ActiveRecord::RecordNotFound if list_id is invalid
- Other errors bubble up from the import service and are handled by Sidekiq's retry mechanism

## Dependencies
- `Music::Albums::List` model
- `DataImporters::Music::Lists::ImportFromMusicbrainzSeries` service

## Usage Context
Typically enqueued by the `Avo::Actions::Lists::ImportFromMusicbrainzSeries` AVO action when admins trigger bulk imports from the admin interface.

## Performance Considerations
- Import duration depends on number of albums in the series
- Each album may trigger additional API calls to MusicBrainz for artist/album data
- Consider rate limiting for large series to avoid overwhelming external APIs

## Monitoring
Job execution and failures are tracked in Sidekiq's built-in monitoring interface. Import progress is logged via Rails logger within the service object.

## Related Classes
- `DataImporters::Music::Lists::ImportFromMusicbrainzSeries` - Core import logic
- `Avo::Actions::Lists::ImportFromMusicbrainzSeries` - Admin action that enqueues this job
- `Music::Albums::List` - Target list model