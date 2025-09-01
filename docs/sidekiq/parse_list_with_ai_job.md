# ParseListWithAiJob

## Summary
Sidekiq background job that processes a single list through AI parsing to extract structured data from raw HTML content. Designed for parallel processing and fault isolation when handling multiple lists.

## Purpose
- Calls `parse_with_ai!` method on a specific list in the background
- Prevents timeout issues in the AVO admin interface during AI processing
- Enables parallel processing of multiple lists when triggered via bulk operations
- Provides proper error handling and logging for AI parsing operations

## Dependencies
- Sidekiq job processing system
- `List` model with `parse_with_ai!` method
- `Services::Lists::ImportService` for AI orchestration
- Rails logging system

## Public Methods

### `#perform(list_id)`
Processes a single list through AI parsing
- Parameters: list_id (Integer) - ID of the list to process
- Returns: None (background job)
- Side effects: Updates list's `simplified_html` and `items_json` fields on success
- Raises: Re-raises exceptions to mark job as failed in Sidekiq

## Error Handling
- **Success**: Logs successful parsing with list ID and name
- **AI Failure**: Logs error message but doesn't raise exception (job marked as successful)
- **Not Found**: Re-raises `ActiveRecord::RecordNotFound` to mark job as failed
- **Other Errors**: Re-raises all other exceptions to mark job as failed and enable Sidekiq retry

## Usage Patterns

### Single List Processing
```ruby
ParseListWithAiJob.perform_async(123)
```

### Bulk Processing (from AVO Action)
```ruby
list_ids.each do |list_id|
  ParseListWithAiJob.perform_async(list_id)
end
```

## Integration Points
- **AVO Actions**: Triggered by `Avo::Actions::Lists::ParseWithAi`
- **List Model**: Calls `List#parse_with_ai!` method
- **AI Services**: Integrates with domain-specific AI parser tasks
- **Sidekiq UI**: Jobs appear individually for better monitoring

## Performance Characteristics
- **Parallel Processing**: Each job runs independently, enabling concurrent processing
- **Memory Efficient**: Processes one list at a time, avoiding bulk memory usage
- **Fault Isolation**: Failed jobs don't affect other lists in bulk operations
- **Retry Support**: Failed jobs can be retried individually through Sidekiq

## Logging
- **Info Level**: Successful parsing completion with list details
- **Error Level**: AI parsing failures and system errors
- **Includes**: List ID, list name, and error messages for debugging

## Design Decisions

### Single List Processing
- **Rationale**: Better parallelization and error isolation compared to bulk processing
- **Trade-off**: More job overhead vs better fault tolerance and monitoring
- **Benefit**: Failed lists don't block processing of successful lists

### Exception Re-raising
- **Rationale**: Proper Sidekiq job status reporting for monitoring and retry logic
- **Pattern**: Log error details, then re-raise to mark job as failed
- **Exception**: AI parsing failures are logged but don't fail the job (business logic failure vs system failure)

### Minimal Dependencies
- **Rationale**: Job focuses solely on orchestration, delegates actual work to List model
- **Benefit**: Easy to test and maintain, clear separation of concerns
- **Pattern**: Job handles infrastructure concerns, model handles business logic

## Testing
- Comprehensive test suite using Mocha mocks
- Tests success scenarios, AI failures, and not-found errors
- Verifies proper exception handling and re-raising
- Uses ActiveSupport::TestCase for Rails integration

---

*Last Updated: September 1, 2025*  
*Related Files: `app/sidekiq/parse_list_with_ai_job.rb`, `test/sidekiq/parse_list_with_ai_job_test.rb`*
