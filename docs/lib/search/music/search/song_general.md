# Search::Music::Search::SongGeneral

## Summary
Executes general full-text search queries against the song index. Provides relevance-ranked results for song searches by title or artist name, enabling users to find songs through multiple search vectors including all artists associated with the song across different albums.

## Public Methods

### `.index_name`
Returns the name of the index to search
- Returns: String - Delegates to Search::Music::SongIndex.index_name
- Ensures search queries target the same index used for indexing

### `.call(text, options = {})`
Performs a general search for songs by title or artist name
- Parameters:
  - text (String) - Search query text
  - options (Hash) - Search options
    - min_score (Float) - Minimum relevance score (default: 1)
    - size (Integer) - Maximum results to return (default: 10)
    - from (Integer) - Offset for pagination (default: 0)
- Returns: Array - Search results with :id, :score, and :source keys
- Returns empty array for blank text input

## Search Strategy

### Multi-Match Query
Uses OpenSearch multi-match query with "most_fields" type across:
- `title` - Song title (analyzed text)
- `title.keyword` - Song title (exact keyword)
- `artist_names` - Array of artist names (analyzed text)
- `artist_names.keyword` - Array of artist names (exact keyword)

### Boost Values
- **Exact match**: 10.0x boost for keyword field matches
- **Phrase match**: 5.0x boost for exact phrase in analyzed text
- **Fuzzy match**: 1.0x boost for standard text matching

### Result Format
Each result contains:
- `:id` - String representation of song ID
- `:score` - Float relevance score from OpenSearch
- `:source` - Hash of indexed document data (title, artist_names, etc.)

## Dependencies
- Search::Base::Search - Base search functionality
- Search::Music::SongIndex - For index name and targeting
- Search::Shared::Utils - For query building utilities

## Usage Examples

```ruby
# Search by song title
results = Search::Music::Search::SongGeneral.call("Come Together")
# Returns songs matching "Come Together" ordered by relevance

# Search by artist name
results = Search::Music::Search::SongGeneral.call("Beatles")
# Returns songs by any artist matching "Beatles"

# Search with options
results = Search::Music::Search::SongGeneral.call("Imagine", {
  size: 5,
  min_score: 3.0
})

# Process results
results.each do |result|
  song_id = result[:id].to_i
  relevance = result[:score]
  song_title = result[:source]["title"]
  artist_names = result[:source]["artist_names"]
  puts "#{song_title} by #{artist_names.join(', ')} (Score: #{relevance})"
end
```

## Search Behavior

### Multi-Field Matching
Songs can be found by either:
1. **Song title**: "Imagine" finds songs titled "Imagine"
2. **Artist name**: "Beatles" finds all Beatles songs
3. **Any associated artist**: Songs appear in results if any album artist matches

### Complex Artist Relationships
Songs can appear on multiple albums with different artists:
- Cover versions on compilation albums
- Collaborative tracks with multiple artists
- Reissues by different artists

The search includes ALL associated artist names, making songs discoverable through any artist connection.

### Exact Matches
Both song titles and artist names that exactly match receive highest scores due to keyword field boost.

### Partial Matches
The folding analyzer enables matching regardless of:
- Case differences ("come together" matches "Come Together")
- Accent differences and punctuation variations
- Common spelling variations

### Empty Results
- Returns empty array for blank/nil input
- Returns empty array when no matches meet min_score threshold
- Gracefully handles OpenSearch connection errors

## Performance Considerations
- Uses multi-match "most_fields" for comprehensive relevance scoring across both title and artist fields
- Configurable result limits prevent oversized responses
- Min_score filtering reduces irrelevant results
- Single index query efficiently handles complex artist relationship searches
- Array field (artist_names) allows matching against multiple artists per song

## Data Complexity
The artist_names field contains all artists associated with the song through its album relationships:
- Primary artists from each album the song appears on
- Enables discovery through cover artists, collaborators, and featured artists
- May result in the same song appearing for searches on different artist names 