# Services::Ai::Tasks::AmazonAlbumMatchTask

## Summary
AI task for validating Amazon Product API search results against Music::Album records. Uses GPT-5 to intelligently determine which Amazon products represent the same musical album, handling variations in titles, artist names, formats, and editions.

## Public Methods

### `#initialize(parent:, search_results:, provider: nil, model: nil)`
Creates new AI validation task
- Parameters:
  - `parent` (Music::Album) - Album to validate against
  - `search_results` (Array) - Amazon product search results to validate
  - `provider` (Symbol, optional) - AI provider override (defaults to :openai)
  - `model` (String, optional) - AI model override (defaults to "gpt-5-mini")

## AI Configuration

### Task Provider
- Uses OpenAI as the AI provider

### Task Model
- Uses "gpt-5-mini" for optimal performance/cost balance
- Temperature set to 1.0 (GPT-5 requirement)

### Response Format
- Uses structured JSON output with RubyLLM::Schema validation
- Returns array of matching results with ASIN, title, artist, and explanation

## Validation Logic

### Matching Criteria
Products are considered matches if:
- Titles represent the same musical work (allowing subtitle/edition variations)
- Artists match (allowing name format variations)
- Product is the actual album, not merchandise or tributes

### Positive Match Examples
- Different editions (remastered, deluxe, anniversary)
- Title format variations ("The Wall" vs "Pink Floyd: The Wall")
- Different formats (CD, vinyl, digital download)
- Artist name variations ("Depeche Mode" vs "DEPECHE MODE")
- Different release years for same album

### Negative Match Examples
- Tribute albums or cover versions
- Merchandise or non-music items
- Different albums by same artist
- Compilation albums (unless original is compilation)
- Individual songs from the album
- Soundtracks containing album songs

## Input Processing

### Album Context
Extracts from parent Music::Album:
- Album title
- Artist names (comma-separated for multiple artists)
- Release year (if available)

### Amazon Product Data
Processes from search results:
- ASIN (Amazon product identifier)
- Product title
- Artist/contributor information
- Format/binding (CD, vinyl, etc.)
- Manufacturer/label
- Release date

## Response Schema

### ResponseSchema Class
Defines structured output format:
```ruby
array :matching_results do
  object do
    string :asin, required: true
    string :title, required: true
    string :artist, required: true
    string :explanation, required: true
  end
end
```

### Return Data
- `matching_results` - Array of validated matches
- Each match includes ASIN, title, artist, and explanation
- Empty array if no matches found

## Dependencies
- Inherits from `Services::Ai::Tasks::BaseTask`
- Uses `RubyLLM::Schema` for response validation
- Returns `Services::Ai::Result` objects
- Integrates with `AiChat` model for conversation persistence

## AI Prompt Engineering

### System Message
Provides comprehensive instructions for music matching expertise, including detailed examples of positive and negative matches.

### User Prompt
Formats album information and Amazon search results in clear, structured format for AI analysis.

## Error Handling
- Inherits error handling from BaseTask
- Schema validation ensures properly formatted responses
- Returns failure results for malformed AI responses

## Performance Considerations
- Uses gpt-5-mini for cost-effective processing
- Processes all search results in single AI call rather than individual requests
- Schema validation prevents downstream processing errors

## Integration Points
- Called by `Services::Music::AmazonProductService`
- Results used to filter Amazon products before creating ExternalLink records
- AI chat conversations stored for audit/debugging purposes