# Music::AmazonProductEnrichmentJob

## Summary
Background job for Amazon Product API enrichment of Music::Album records. Processes albums asynchronously to add Amazon product links, pricing information, and download primary album artwork without blocking the main import workflow.

## Queue Configuration
- **Queue**: `:serial`
- **Concurrency**: 1 (configured via Sidekiq capsule)
- **Purpose**: Prevents API rate limiting violations on Amazon Product API

## Public Methods

### `#perform(album_id)`
Main job execution method
- Parameters:
  - `album_id` (Integer) - ID of Music::Album to enrich
- Side Effects: Creates ExternalLink records, downloads images, updates album data
- Error Handling: Raises StandardError on service failures to trigger Sidekiq retry logic

## Workflow
1. **Load Album**: Finds Music::Album by ID
2. **Service Delegation**: Calls `Services::Music::AmazonProductService` for all processing
3. **Result Handling**: Logs success/failure and raises errors for retry handling
4. **Logging**: Comprehensive logging for monitoring and debugging

## Dependencies
- `Services::Music::AmazonProductService` - Core Amazon integration logic
- `Music::Album` model - Target of enrichment
- Sidekiq framework for background processing

## Error Handling
- Service failures are converted to StandardError exceptions
- Sidekiq retry logic handles transient failures (network issues, API rate limits)
- Comprehensive error logging for debugging
- Failed jobs can be retried manually or automatically

## Sidekiq Configuration
```ruby
sidekiq_options queue: :serial
```

## Serial Queue Benefits
- **API Rate Limiting**: Prevents overwhelming Amazon Product API
- **Resource Management**: Avoids concurrent expensive operations
- **Reliability**: Ensures proper error handling without race conditions

## Logging
- Start/completion messages with album titles
- Success confirmations for monitoring
- Detailed error messages for troubleshooting
- Integrates with existing Rails logging infrastructure

## Integration Points
- **Triggered by**: `DataImporters::Music::Album::Providers::Amazon`
- **Processes**: Amazon API search, AI validation, external links, image downloads
- **Updates**: Music::Album with ExternalLink records and primary images

## Monitoring
- Job status visible in Sidekiq Web UI
- Logs provide enrichment progress tracking
- Failed jobs indicate API or validation issues
- Retry counts help identify persistent problems

## Performance Considerations
- Serial processing prevents API rate limit violations
- Service object handles all expensive operations
- Background execution doesn't block user workflows
- Failed jobs automatically retry with exponential backoff

## Operational Notes
- Jobs may take several seconds due to external API calls
- Amazon API credentials must be configured for jobs to succeed
- Image downloads may fail due to network issues (handled gracefully)
- AI validation step may introduce additional latency