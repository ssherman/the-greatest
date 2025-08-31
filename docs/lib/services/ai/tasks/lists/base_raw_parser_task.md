# Services::Ai::Tasks::Lists::BaseRawParserTask

## Summary
Abstract base class for AI-powered list parsing tasks. Provides common infrastructure for extracting structured data from simplified HTML lists across different media types (music, books, movies, games). Uses OpenAI's GPT-5 Mini for consistent JSON extraction.

## Public Methods

### `#initialize(parent:, provider: nil, model: nil)`
Creates task instance for list parsing
- Parameters:
  - `parent` (List) - The list object containing simplified_html to parse
  - `provider` (Symbol, optional) - Override default provider
  - `model` (String, optional) - Override default model
- Inherits: From BaseTask

### `#call`
Executes list parsing workflow
- Returns: Services::Ai::Result with extracted structured data
- Side effects: Updates parent list's items_json field with parsed data
- Error handling: Returns failure result on parsing or database errors

## Protected Methods (Overridden)

### `#task_provider`
Specifies OpenAI as preferred provider
- Returns: `:openai`
- Reason: Superior JSON schema support and structured output reliability

### `#task_model`
Specifies GPT-5 Mini as preferred model
- Returns: `"gpt-5-mini"`
- Reason: Latest model optimized for structured extraction tasks

### `#temperature`
Sets temperature for consistent parsing
- Returns: `1.0`
- Note: GPT-5 does not support temperature parameter

### `#chat_type`
Defines chat interaction type
- Returns: `:analysis`
- Purpose: Categorizes AI interaction for logging and tracking

### `#system_message`
Generates media-type specific system prompt
- Returns: String instructing AI on extraction rules
- Content: Emphasizes data extraction only, no research or enhancement
- Uses: `media_type`, `extraction_fields`, `media_specific_instructions`

### `#user_prompt`
Creates list-specific extraction prompt
- Returns: String with HTML content and extraction instructions
- Includes: List context (name, source), simplified HTML, extraction examples
- Uses: `parent.simplified_html`, `list_source_context`, `extraction_examples`

### `#response_format`
Specifies JSON object response format
- Returns: `{ type: "json_object" }`
- Purpose: Ensures structured response for reliable parsing

### `#process_and_persist(provider_response)`
Processes AI response and updates parent list
- Parameters: provider_response (Hash) - Raw AI response with content
- Returns: Services::Ai::Result with success status and parsed data
- Logic: Parses JSON, updates parent.items_json, creates result with ai_chat

## Abstract Methods (Must Override)

### `#media_type`
Defines the media type being parsed
- Returns: String (e.g., "albums", "songs", "books")
- Purpose: Used in prompts and response structure
- Must implement: Subclasses must override

### `#extraction_fields`
Lists the fields to extract for this media type
- Returns: Array of String descriptions
- Purpose: Included in system prompt to guide AI extraction
- Must implement: Subclasses must override

### `#media_specific_instructions` (Optional)
Provides additional parsing guidance for media type
- Returns: String with specialized instructions
- Default: Empty string
- Purpose: Media-specific context and rules

### `#extraction_examples` (Optional)
Shows example extractions for this media type
- Returns: String with formatted examples
- Default: Empty string
- Purpose: Improves AI parsing accuracy through few-shot learning

## Helper Methods

### `#list_source_context`
Generates context about the list source for prompts
- Returns: String describing list origin
- Logic: Uses parent.source, parent.url, or "unknown source" fallback
- Purpose: Provides context to improve AI understanding

## Usage Pattern

```ruby
# Subclass implementation
class AlbumsRawParserTask < BaseRawParserTask
  private
  
  def media_type = "albums"
  
  def extraction_fields
    ["Rank", "Album title", "Artist name(s)", "Release year"]
  end
  
  def media_specific_instructions
    "Albums typically have a primary artist..."
  end
end

# Usage
task = Services::Ai::Tasks::Lists::Music::AlbumsRawParserTask.new(parent: list)
result = task.call
```

## Response Structure
All subclasses should return JSON with media_type as root key:
```json
{
  "albums": [
    {
      "rank": 1,
      "title": "Album Title",
      "artists": ["Artist Name"],
      "release_year": 2023
    }
  ]
}
```

## Error Handling
- Invalid parent: ArgumentError during initialization
- AI provider errors: Caught and returned as failure result
- JSON parsing errors: Caught and returned as failure result
- Database update errors: Caught and returned as failure result

## Dependencies
- Services::Ai::Tasks::BaseTask (parent class)
- List model as parent (with simplified_html field)
- OpenAI API for default provider
- JSON parsing for response processing

## Performance Considerations
- Uses GPT-5 Mini for cost efficiency and speed
- Structured JSON output reduces parsing overhead
- Single database update per successful parsing
- Memoized provider client reduces API setup time

## Design Notes
This abstract base class implements the Template Method pattern, allowing subclasses to customize media-specific behavior while providing consistent infrastructure for HTML parsing, AI interaction, and result persistence. The focus on extraction-only (no research) ensures fast, reliable parsing of list data.