# Services::Lists::ImportService

## Summary
Orchestrator service for importing and processing HTML lists into structured data. Coordinates HTML simplification and AI-powered parsing to extract list items from raw HTML. Supports multiple media types through STI-based list type detection and routing to appropriate parser tasks.

## Public Methods

### `self.call(list)`
Class method for convenient list import processing
- Parameters: `list` (List) - List object with raw_html to process
- Returns: Hash with success status and data/error
- Usage: Direct class method call for stateless operation

### `#initialize(list)`
Creates service instance with list to process
- Parameters: `list` (List) - List object containing raw HTML
- Purpose: Instance-based approach for more complex processing scenarios

### `#call`
Executes the complete list import workflow
- Returns: Hash with success/failure status and data/error message
- Process: HTML simplification → Parser selection → AI extraction → Result handling
- Side effects: Updates list's simplified_html and items_json fields

## Processing Workflow

### Step 1: Input Validation
```ruby
return failure("List has no raw HTML") if @list.raw_html.blank?
```
- Validates that list contains raw HTML content
- Returns failure immediately if no HTML to process

### Step 2: HTML Simplification
```ruby
simplified_html = Services::Html::SimplifierService.call(@list.raw_html)
@list.update!(simplified_html: simplified_html)
```
- Uses SimplifierService to clean and prepare HTML
- Stores simplified HTML in list for debugging and re-processing
- Makes HTML suitable for AI parsing

### Step 3: Parser Selection
```ruby
parser_class = determine_parser_class
return failure("No parser available for list type: #{@list.type}") unless parser_class
```
- Routes to appropriate parser based on STI list type
- Returns failure if no parser exists for the media type

### Step 4: AI Parsing Execution
```ruby
result = parser_class.new(parent: @list).call
```
- Instantiates and executes media-specific parser task
- Passes list as parent for context and data storage
- Returns AI parsing result with extracted data

### Step 5: Result Processing
```ruby
if result.success?
  success(result.data)
else
  failure(result.error)
end
```
- Forwards parser result to caller
- Maintains consistent success/failure format

## Private Methods

### `#determine_parser_class`
Maps STI list types to appropriate parser classes
- Returns: Parser class constant or nil
- Logic: Switch statement based on @list.type
- Purpose: Enables polymorphic parsing based on list media type

#### Supported List Types and Parsers
```ruby
case @list.type
when "Music::Albums::List"
  Services::Ai::Tasks::Lists::Music::AlbumsRawParserTask
when "Music::Songs::List"
  Services::Ai::Tasks::Lists::Music::SongsRawParserTask
when "Books::List"
  Services::Ai::Tasks::Lists::Books::RawParserTask
when "Movies::List"
  Services::Ai::Tasks::Lists::Movies::RawParserTask  
when "Games::List"
  Services::Ai::Tasks::Lists::Games::RawParserTask
else
  nil
end
```

### `#success(data)`
Creates successful result hash
- Parameters: `data` - Parsed data from AI task
- Returns: `{ success: true, data: data }`
- Purpose: Standardized success response format

### `#failure(error)`
Creates failure result hash  
- Parameters: `error` - Error message string
- Returns: `{ success: false, error: error }`
- Purpose: Standardized error response format

## Result Format

### Success Response
```ruby
{
  success: true,
  data: {
    albums: [
      { rank: 1, title: "Album Name", artists: ["Artist"], release_year: 2023 }
    ]
  }
}
```

### Failure Response
```ruby
{
  success: false,
  error: "Error message describing the failure"
}
```

## Usage Examples

### Basic Usage
```ruby
list = Music::Albums::List.find(123)
result = Services::Lists::ImportService.call(list)

if result[:success]
  puts "Extracted #{result[:data][:albums].length} albums"
  # List now has simplified_html and items_json populated
else
  puts "Import failed: #{result[:error]}"
end
```

### Instance-based Usage
```ruby
service = Services::Lists::ImportService.new(list)
result = service.call
```

### Processing Multiple Lists
```ruby
lists = List.where(items_json: nil)
lists.find_each do |list|
  result = Services::Lists::ImportService.call(list)
  if result[:success]
    puts "✓ Processed #{list.name}"
  else
    puts "✗ Failed #{list.name}: #{result[:error]}"
  end
end
```

### Error Handling Patterns
```ruby
result = Services::Lists::ImportService.call(list)

case result
in { success: true, data: }
  # Process successful extraction
  handle_extracted_data(data)
in { success: false, error: }
  # Handle specific error types
  case error
  when /No parser available/
    log_unsupported_list_type(list)
  when /no raw HTML/
    log_missing_html(list)
  else
    log_general_error(list, error)
  end
end
```

## Error Handling

### Input Validation Errors
- **Missing HTML**: "List has no raw HTML"
- **Invalid List Type**: "No parser available for list type: #{type}"

### Processing Errors
- **HTML Simplification**: Passes through SimplifierService errors
- **AI Parsing**: Passes through parser task errors
- **Database Updates**: Database constraint or connection errors

### Parser Task Errors
- **AI Provider**: API rate limits, authentication, network issues
- **JSON Parsing**: Malformed AI responses
- **Schema Validation**: Invalid data structure from AI

## Integration Points

### Upstream Dependencies
- **List Models**: Requires STI list subclasses with raw_html field
- **SimplifierService**: For HTML preprocessing
- **Parser Tasks**: Media-specific AI parsing implementations

### Downstream Effects
- **Database Updates**: Modifies list.simplified_html and list.items_json
- **AI Chat Logs**: Parser tasks create AiChat records for tracking
- **Result Processing**: Enables further processing of structured data

## Performance Considerations

### Processing Time
- **HTML Simplification**: Fast, single-pass processing
- **AI Parsing**: Depends on HTML complexity and AI provider response time
- **Database Updates**: Two update operations per successful import

### Memory Usage
- **HTML Processing**: Nokogiri DOM creates temporary memory overhead
- **Result Storage**: JSON data stored in PostgreSQL JSONB field
- **Large Lists**: Memory scales with HTML size and item count

### Scalability
- **Batch Processing**: Designed for single-list processing, can be parallelized
- **AI Rate Limits**: Subject to provider rate limiting
- **Database Load**: Two writes per list, readable for monitoring

## Design Patterns

### Template Method
- Defines processing workflow structure
- Delegates media-specific logic to parser tasks
- Enables consistent processing across media types

### Strategy Pattern  
- Router pattern for parser selection
- Enables easy addition of new media types
- Polymorphic behavior based on list type

### Service Object
- Single responsibility for list import coordination
- Stateless operation with clear input/output
- Composable with other services

## Future Enhancements

### Additional Media Types
```ruby
when "Podcasts::List"
  Services::Ai::Tasks::Lists::Podcasts::RawParserTask
when "TV::Shows::List"  
  Services::Ai::Tasks::Lists::TV::ShowsRawParserTask
```

### Batch Processing
- Process multiple lists in single API calls
- Parallel processing for improved throughput
- Progress tracking for long-running batch operations

### Retry Logic
- Exponential backoff for transient AI provider errors
- Selective retry based on error type
- Circuit breaker pattern for provider outages

### Caching
- Cache simplified HTML for repeated processing
- Memoize parser class determination
- Cache successful parsing results

## Dependencies
- Services::Html::SimplifierService for HTML preprocessing
- Media-specific parser task classes for AI extraction
- List STI hierarchy for type-based routing
- PostgreSQL JSONB for structured data storage

## Testing Considerations
- Mock AI provider responses for consistent testing
- Test each supported list type and parser combination
- Verify database updates and rollback scenarios
- Test error handling for each failure mode
- Performance testing with various HTML sizes and complexities