# Services::Ai::Tasks::Lists::Music::AlbumsRawParserTask

## Summary
AI task for extracting music album information from simplified HTML lists. Specializes in parsing album titles, artists, rankings, and release years from various list formats. Inherits from BaseRawParserTask and provides album-specific parsing logic and validation schema.

## Public Methods

### `#initialize(parent:, provider: nil, model: nil)`
Creates task instance for album list parsing
- Parameters:
  - `parent` (Music::Albums::List) - The music album list to parse
  - `provider` (Symbol, optional) - Override default provider  
  - `model` (String, optional) - Override default model
- Inherits: From BaseRawParserTask

### `#call`
Executes album parsing workflow
- Returns: Services::Ai::Result with album data array
- Side effects: Updates parent list's items_json with structured album data
- Error handling: Returns failure result on parsing or validation errors

## Protected Methods (Overridden)

### `#media_type`
Specifies albums as the media type
- Returns: `"albums"`
- Purpose: Used in prompts and response structure

### `#extraction_fields`
Defines album-specific fields to extract
- Returns: Array of field descriptions:
  - "Rank (if present, can be null)"
  - "Album title"  
  - "Artist name(s)"
  - "Release year (if present, can be null)"
- Purpose: Guides AI extraction and ensures consistent data structure

### `#media_specific_instructions`
Provides album-specific parsing guidance
- Returns: String with album parsing rules:
  - Albums typically have primary artist but may have multiple
  - Release year may be in parentheses or separate text
  - Album titles should not include artist names unless part of actual title
- Purpose: Improves accuracy for album-specific patterns

### `#extraction_examples`
Shows example album extractions
- Returns: String with formatted examples:
  - "1. The Dark Side of the Moon - Pink Floyd (1973)" → rank: 1, title: "The Dark Side of the Moon", artists: ["Pink Floyd"], release_year: 1973
  - "Abbey Road by The Beatles" → rank: null, title: "Abbey Road", artists: ["The Beatles"], release_year: null
- Purpose: Few-shot learning to improve extraction accuracy

### `#response_schema`
Defines expected response structure
- Returns: `ResponseSchema` class
- Purpose: Validates AI response format and field types

## Response Schema

### ResponseSchema (Inner Class)
RubyLLM::Schema defining album response structure

#### Schema Definition
```ruby
array :albums do
  object do
    integer :rank, required: false, description: "Rank position in the list"
    string :title, required: true, description: "Album title"
    array :artists, of: :string, description: "Artist name(s)"
    integer :release_year, required: false, description: "Year the album was released"
  end
end
```

#### Field Specifications
- `rank` (Integer, optional) - Position in ranked list, null if unranked
- `title` (String, required) - Full album title without artist names
- `artists` (Array[String], required) - All contributing artists
- `release_year` (Integer, optional) - Year of original release

#### Validation Rules
- Title must not be empty
- Artists array must contain at least one string
- Rank and release_year can be null
- All fields properly typed for database storage

## Response Examples

### Ranked Album List
```json
{
  "albums": [
    {
      "rank": 1,
      "title": "Abbey Road", 
      "artists": ["The Beatles"],
      "release_year": 1969
    },
    {
      "rank": 2,
      "title": "Pet Sounds",
      "artists": ["The Beach Boys"], 
      "release_year": 1966
    }
  ]
}
```

### Unranked Album List
```json
{
  "albums": [
    {
      "rank": null,
      "title": "OK Computer",
      "artists": ["Radiohead"],
      "release_year": 1997
    }
  ]
}
```

### Multi-Artist Album
```json
{
  "albums": [
    {
      "rank": 5,
      "title": "Watch the Throne",
      "artists": ["Jay-Z", "Kanye West"],
      "release_year": 2011
    }
  ]
}
```

## Parsing Patterns

### Common Album Formats
- "Rank. Album Title - Artist (Year)"
- "Album Title by Artist"  
- "Artist - Album Title"
- "Album Title (Artist, Year)"
- "Album Title | Artist | Year"

### Multi-Artist Handling
- "Album Title - Artist A & Artist B"
- "Album Title - Artist A feat. Artist B"  
- "Album Title - Various Artists"

### Year Extraction
- Parentheses: "(1973)"
- Brackets: "[1973]" 
- Standalone: "Released 1973"
- Range: "1973-1974" (takes first year)

## Error Handling
- Invalid list parent: ArgumentError during initialization
- Missing required fields: Validation error in schema
- Unparseable HTML: Returns empty albums array
- AI provider errors: Caught and returned as failure result
- Database update errors: Caught and returned as failure result

## Usage Examples

### Basic Usage
```ruby
albums_list = Music::Albums::List.find(123)
task = Services::Ai::Tasks::Lists::Music::AlbumsRawParserTask.new(parent: albums_list)
result = task.call

if result.success?
  albums_data = result.data[:albums]
  puts "Extracted #{albums_data.length} albums"
else
  puts "Parsing failed: #{result.error}"
end
```

### With Custom Provider
```ruby
task = Services::Ai::Tasks::Lists::Music::AlbumsRawParserTask.new(
  parent: albums_list,
  provider: :anthropic,
  model: "claude-3-sonnet"
)
result = task.call
```

## Dependencies
- Services::Ai::Tasks::Lists::BaseRawParserTask (parent class)
- Music::Albums::List model as parent
- RubyLLM::Schema for response validation
- OpenAI API for default provider

## Performance Considerations
- Optimized for album-specific patterns and terminology
- Schema validation ensures clean data structure
- Single database update per successful parsing
- Handles large lists efficiently through streaming JSON parsing

## Design Notes
This task specializes the base parser for music albums, providing domain-specific prompts, examples, and validation. The schema ensures consistent data structure while allowing for optional fields that may not be present in all list formats. The multi-artist support handles complex crediting scenarios common in music albums.