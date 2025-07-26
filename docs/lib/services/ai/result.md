# Services::Ai::Result

## Summary
Standardized result object for AI service operations. Provides consistent success/failure handling with data, error information, and associated chat context across all AI tasks.

## Public Methods

### `#initialize(success:, data: nil, error: nil, ai_chat: nil)`
Creates a new result instance
- Parameters:
  - `success` (Boolean) - Whether the operation succeeded
  - `data` (Hash, optional) - Operation result data
  - `error` (String, optional) - Error message if failed
  - `ai_chat` (AiChat, optional) - Associated chat record
- Validation: Exactly one of data or error should be provided

### `#success?`
Checks if the operation was successful
- Returns: Boolean indicating success status
- Usage: `result.success?` returns true/false

### `#failure?`
Checks if the operation failed
- Returns: Boolean indicating failure status (opposite of success?)
- Usage: `result.failure?` returns true/false

## Attributes

### `#success`
Read-only access to success status
- Type: Boolean
- Usage: `result.success` returns true/false

### `#data`
Read-only access to operation result data
- Type: Hash or nil
- Usage: `result.data` returns operation data or nil
- Content: Typically contains parsed AI response data

### `#error`
Read-only access to error message
- Type: String or nil
- Usage: `result.error` returns error message or nil
- Content: Human-readable error description

### `#ai_chat`
Read-only access to associated chat record
- Type: AiChat or nil
- Usage: `result.ai_chat` returns chat record or nil
- Content: Complete conversation history and metadata

## Usage Patterns

### Success Result
```ruby
result = Services::Ai::Result.new(
  success: true,
  data: { name: "David Bowie", country: "GB" },
  ai_chat: chat_record
)

if result.success?
  puts "Artist: #{result.data[:name]}"
  puts "Chat ID: #{result.ai_chat.id}"
end
```

### Failure Result
```ruby
result = Services::Ai::Result.new(
  success: false,
  error: "API rate limit exceeded",
  ai_chat: chat_record
)

if result.failure?
  puts "Error: #{result.error}"
  puts "Chat messages: #{result.ai_chat.messages.length}"
end
```

### Pattern Matching
```ruby
case result
when ->(r) { r.success? }
  process_success(result.data)
when ->(r) { r.failure? }
  handle_error(result.error)
end
```

### Chaining Operations
```ruby
def process_artist(artist)
  result = extract_details(artist)
  return result if result.failure?
  
  result = enrich_data(result.data)
  return result if result.failure?
  
  result
end
```

## Factory Methods

### Success Results
```ruby
# From task classes
def process_and_persist(provider_response)
  data = provider_response[:parsed]
  parent.update!(data)
  Services::Ai::Result.new(success: true, data: data, ai_chat: chat)
end
```

### Failure Results
```ruby
# From error handling
rescue StandardError => e
  Services::Ai::Result.new(success: false, error: e.message)
end
```

## Common Data Structures

### Artist Details Data
```ruby
{
  artist_known: true,
  description: "Innovative English singer-songwriter",
  country: "GB",
  kind: "person"
}
```

### Provider Response Data
```ruby
{
  content: '{"name": "David Bowie"}',
  parsed: { name: "David Bowie" },
  id: "chatcmpl-123",
  model: "gpt-4",
  usage: { prompt_tokens: 10, completion_tokens: 5 }
}
```

## Error Types

### Provider Errors
- Network timeouts
- API rate limits
- Invalid API keys
- Model unavailable

### Validation Errors
- Invalid parent object
- Missing required fields
- Schema validation failures

### Database Errors
- Record creation failures
- Update constraint violations
- Connection issues

## Design Notes
This class follows the Result pattern (similar to Rust's Result type) to provide explicit success/failure handling without exceptions. It encourages callers to handle both success and failure cases explicitly, improving error handling and code reliability. The inclusion of the ai_chat provides full context for debugging and audit trails. 