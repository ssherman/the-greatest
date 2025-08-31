# Services::Ai::Tasks::Lists::Music::SongsRawParserTask

## Summary
AI task for extracting music song information from simplified HTML lists. Specializes in parsing song titles, artists, album information, rankings, and release years from various list formats. Inherits from BaseRawParserTask and provides song-specific parsing logic and validation schema.

## Public Methods

### `#initialize(parent:, provider: nil, model: nil)`
Creates task instance for song list parsing
- Parameters:
  - `parent` (Music::Songs::List) - The music songs list to parse
  - `provider` (Symbol, optional) - Override default provider
  - `model` (String, optional) - Override default model
- Inherits: From BaseRawParserTask

### `#call`
Executes song parsing workflow
- Returns: Services::Ai::Result with song data array
- Side effects: Updates parent list's items_json with structured song data
- Error handling: Returns failure result on parsing or validation errors

## Protected Methods (Overridden)

### `#media_type`
Specifies songs as the media type
- Returns: `"songs"`
- Purpose: Used in prompts and response structure

### `#extraction_fields`
Defines song-specific fields to extract
- Returns: Array of field descriptions:
  - "Rank (if present, can be null)"
  - "Song title"
  - "Artist name(s)"
  - "Album name (if present, can be null)"
  - "Release year (if present, can be null)"
- Purpose: Guides AI extraction and ensures consistent data structure

### `#media_specific_instructions`
Provides song-specific parsing guidance
- Returns: String with song parsing rules:
  - Songs may be listed with or without album information
  - Featured artists should be included in the artists array
  - Duration may be present but is not required for extraction
  - Multiple versions (live, remix, etc.) should be noted if present
- Purpose: Improves accuracy for song-specific patterns

### `#extraction_examples`
Shows example song extractions
- Returns: String with formatted examples:
  - "1. Bohemian Rhapsody - Queen (A Night at the Opera, 1975)" → rank: 1, title: "Bohemian Rhapsody", artists: ["Queen"], album: "A Night at the Opera", release_year: 1975
  - "Imagine by John Lennon" → rank: null, title: "Imagine", artists: ["John Lennon"], album: null, release_year: null
- Purpose: Few-shot learning to improve extraction accuracy

### `#response_schema`
Defines expected response structure
- Returns: `ResponseSchema` class
- Purpose: Validates AI response format and field types

## Response Schema

### ResponseSchema (Inner Class)
RubyLLM::Schema defining song response structure

#### Schema Definition
```ruby
array :songs do
  object do
    integer :rank, required: false, description: "Rank position in the list"
    string :title, required: true, description: "Song title"
    array :artists, of: :string, description: "Artist name(s)"
    string :album, required: false, description: "Album name if present"
    integer :release_year, required: false, description: "Year the song was released"
  end
end
```

#### Field Specifications
- `rank` (Integer, optional) - Position in ranked list, null if unranked
- `title` (String, required) - Full song title
- `artists` (Array[String], required) - All contributing artists including featured artists
- `album` (String, optional) - Album name if mentioned in list
- `release_year` (Integer, optional) - Year of original release

#### Validation Rules
- Title must not be empty
- Artists array must contain at least one string
- Rank, album, and release_year can be null
- All fields properly typed for database storage

## Response Examples

### Ranked Song List with Albums
```json
{
  "songs": [
    {
      "rank": 1,
      "title": "Bohemian Rhapsody",
      "artists": ["Queen"],
      "album": "A Night at the Opera",
      "release_year": 1975
    },
    {
      "rank": 2,
      "title": "Stairway to Heaven",
      "artists": ["Led Zeppelin"],
      "album": "Led Zeppelin IV",
      "release_year": 1971
    }
  ]
}
```

### Unranked Song List without Albums
```json
{
  "songs": [
    {
      "rank": null,
      "title": "Imagine",
      "artists": ["John Lennon"],
      "album": null,
      "release_year": 1971
    }
  ]
}
```

### Songs with Featured Artists
```json
{
  "songs": [
    {
      "rank": 5,
      "title": "Empire State of Mind",
      "artists": ["Jay-Z", "Alicia Keys"],
      "album": "The Blueprint 3",
      "release_year": 2009
    }
  ]
}
```

### Songs with Versions/Remixes
```json
{
  "songs": [
    {
      "rank": 10,
      "title": "Hurt (Johnny Cash version)",
      "artists": ["Johnny Cash"],
      "album": "American IV: The Man Comes Around",
      "release_year": 2002
    }
  ]
}
```

## Parsing Patterns

### Common Song Formats
- "Rank. Song Title - Artist (Album, Year)"
- "Song Title by Artist"
- "Artist - Song Title"
- "Song Title | Artist | Album | Year"
- "Song Title (Artist)"

### Featured Artist Handling
- "Song Title - Artist feat. Featured Artist"
- "Song Title - Artist ft. Featured Artist"
- "Song Title - Artist & Featured Artist"
- "Song Title - Artist vs. Featured Artist"

### Album Information Extraction
- Parentheses: "(Album Name, Year)"
- Brackets: "[Album Name]"
- From: "from Album Name"
- Off: "off Album Name"

### Version/Remix Handling
- "Song Title (Live)"
- "Song Title (Remix)"
- "Song Title (Acoustic Version)"
- "Song Title (Radio Edit)"

## Error Handling
- Invalid list parent: ArgumentError during initialization
- Missing required fields: Validation error in schema
- Unparseable HTML: Returns empty songs array
- AI provider errors: Caught and returned as failure result
- Database update errors: Caught and returned as failure result

## Usage Examples

### Basic Usage
```ruby
songs_list = Music::Songs::List.find(123)
task = Services::Ai::Tasks::Lists::Music::SongsRawParserTask.new(parent: songs_list)
result = task.call

if result.success?
  songs_data = result.data[:songs]
  puts "Extracted #{songs_data.length} songs"
else
  puts "Parsing failed: #{result.error}"
end
```

### With Custom Provider
```ruby
task = Services::Ai::Tasks::Lists::Music::SongsRawParserTask.new(
  parent: songs_list,
  provider: :anthropic,
  model: "claude-3-sonnet"
)
result = task.call
```

### Processing Results
```ruby
result = task.call
if result.success?
  result.data[:songs].each do |song|
    puts "#{song[:title]} by #{song[:artists].join(', ')}"
    puts "  Album: #{song[:album]}" if song[:album]
    puts "  Year: #{song[:release_year]}" if song[:release_year]
  end
end
```

## Dependencies
- Services::Ai::Tasks::Lists::BaseRawParserTask (parent class)
- Music::Songs::List model as parent
- RubyLLM::Schema for response validation
- OpenAI API for default provider

## Performance Considerations
- Optimized for song-specific patterns and terminology
- Schema validation ensures clean data structure
- Single database update per successful parsing
- Handles large playlists efficiently through streaming JSON parsing
- Featured artist extraction adds complexity but maintains accuracy

## Design Notes
This task specializes the base parser for music songs, providing domain-specific prompts, examples, and validation. The schema accommodates the more complex nature of songs compared to albums, including optional album information and support for featured artists. The flexible artist array handles various crediting scenarios common in popular music, while the optional album field allows for both album-based and standalone song lists.