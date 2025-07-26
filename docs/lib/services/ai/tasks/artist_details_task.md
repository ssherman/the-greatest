# Services::Ai::Tasks::ArtistDetailsTask

## Summary
AI task for extracting detailed information about musical artists. Analyzes artist names and returns structured data including description, country, and type (person/band). Only updates the artist record when the AI confidently knows the artist.

## Public Methods

### `#initialize(parent:, provider: nil, model: nil)`
Creates task instance for artist analysis
- Parameters:
  - `parent` (Music::Artist) - The artist to analyze
  - `provider` (Symbol, optional) - Override default provider
  - `model` (String, optional) - Override default model
- Inherits: From BaseTask

### `#call`
Executes artist analysis workflow
- Returns: Services::Ai::Result with artist data and confidence
- Side effects: May update artist record if AI is confident about the artist
- Error handling: Returns failure result on any errors

## Protected Methods (Overridden)

### `#task_provider`
Specifies OpenAI as preferred provider
- Returns: `:openai`
- Reason: OpenAI GPT-4 performs well on music knowledge tasks

### `#task_model`
Specifies GPT-4o as preferred model
- Returns: `"gpt-4o"`
- Reason: Latest model with good structured output support

### `#system_message`
Provides expert music knowledge system prompt
- Returns: String instructing AI to act as music expert
- Content: Emphasizes accuracy and honesty about uncertainty

### `#user_prompt`
Generates artist-specific analysis prompt
- Returns: String with structured request for artist information
- Includes: Artist name, specific field requirements, confidence instructions

### `#response_format`
Specifies JSON object response format
- Returns: `{ type: "json_object" }`
- Purpose: Ensures structured response for parsing

### `#response_schema`
Defines expected response structure
- Returns: `ResponseSchema` class
- Schema: Includes `artist_known`, `description`, `country`, `kind` fields

### `#process_and_persist(provider_response)`
Processes AI response and conditionally updates artist
- Parameters: provider_response (Hash) - Parsed AI response
- Returns: Services::Ai::Result with success status and data
- Logic: Only updates artist if `artist_known` is true

## Response Schema

### ResponseSchema (Inner Class)
RubyLLM::Schema defining expected AI response structure

#### Fields
- `artist_known` (Boolean, required) - Whether AI recognizes the artist
- `description` (String, optional) - Brief artist description and style/genre
- `country` (String, optional) - ISO-3166 alpha-2 country code
- `kind` (String, optional) - Either "person" or "band"

#### Validation
- `artist_known` must be boolean
- `kind` must be "person" or "band" if provided
- `country` should be valid ISO country code

## Behavior Patterns

### Known Artist Response
```json
{
  "artist_known": true,
  "description": "Innovative English singer-songwriter and actor",
  "country": "GB",
  "kind": "person"
}
```
- Updates artist record with provided information
- Returns success with extracted data

### Unknown Artist Response
```json
{
  "artist_known": false,
  "description": null,
  "country": null,
  "kind": null
}
```
- Does NOT update artist record
- Returns success but with no data changes

## Usage Examples

### Basic usage
```ruby
task = Services::Ai::Tasks::ArtistDetailsTask.new(parent: artist)
result = task.call

if result.success?
  if result.data[:artist_known]
    puts "Updated artist: #{result.data[:description]}"
  else
    puts "AI doesn't know this artist"
  end
else
  puts "Error: #{result.error}"
end
```

### With custom provider/model
```ruby
task = Services::Ai::Tasks::ArtistDetailsTask.new(
  parent: artist,
  provider: :anthropic,
  model: "claude-3-sonnet"
)
result = task.call
```

## Error Handling
- Invalid artist parent: ArgumentError during initialization
- AI provider errors: Caught and returned as failure result
- Database update errors: Caught and returned as failure result
- JSON parsing errors: Handled by parent class

## Dependencies
- Services::Ai::Tasks::BaseTask (parent class)
- Music::Artist model as parent
- RubyLLM::Schema for response validation
- OpenAI API for default provider

## Performance Considerations
- Uses GPT-4o for better accuracy on music knowledge
- Structured output reduces parsing overhead
- Conditional updates prevent unnecessary database writes
- Memoized provider client reduces API setup time

## Design Notes
This task prioritizes accuracy over coverage by allowing the AI to indicate uncertainty. The `artist_known` field prevents updating records with potentially incorrect information, maintaining data quality while still providing useful AI insights when available. 