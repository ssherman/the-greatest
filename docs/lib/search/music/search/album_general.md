# Search::Music::Search::AlbumGeneral

## Summary
Executes general full-text search queries against the album index. Provides relevance-ranked results for album searches by title or artist name, enabling users to find albums through multiple search vectors.

## Public Methods

### `.index_name`
Returns the name of the index to search
- Returns: String - Delegates to Search::Music::AlbumIndex.index_name
- Ensures search queries target the same index used for indexing

### `.call(text, options = {})`
Performs a general search for albums by title or artist name
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
- `title` - Album title (analyzed text)
- `title.keyword` - Album title (exact keyword)
- `primary_artist_name` - Artist name (analyzed text)
- `primary_artist_name.keyword` - Artist name (exact keyword)

### Boost Values
- **Exact match**: 10.0x boost for keyword field matches
- **Phrase match**: 5.0x boost for exact phrase in analyzed text
- **Fuzzy match**: 1.0x boost for standard text matching

### Result Format
Each result contains:
- `:id` - String representation of album ID
- `:score` - Float relevance score from OpenSearch
- `:source` - Hash of indexed document data (title, primary_artist_name, etc.)

## Dependencies
- Search::Base::Search - Base search functionality
- Search::Music::AlbumIndex - For index name and targeting
- Search::Shared::Utils - For query building utilities

## Usage Examples

```ruby
# Search by album title
results = Search::Music::Search::AlbumGeneral.call("Abbey Road")
# Returns albums matching "Abbey Road" ordered by relevance

# Search by artist name
results = Search::Music::Search::AlbumGeneral.call("Beatles")
# Returns albums by artists matching "Beatles"

# Search with options
results = Search::Music::Search::AlbumGeneral.call("White Album", {
  size: 3,
  min_score: 2.0
})

# Process results
results.each do |result|
  album_id = result[:id].to_i
  relevance = result[:score]
  album_title = result[:source]["title"]
  artist_name = result[:source]["primary_artist_name"]
  puts "#{album_title} by #{artist_name} (Score: #{relevance})"
end
```

## Search Behavior

### Multi-Field Matching
Albums can be found by either:
1. **Album title**: "Sgt Pepper" finds "Sgt. Pepper's Lonely Hearts Club Band"
2. **Artist name**: "Beatles" finds all Beatles albums
3. **Combined**: "Beatles White" finds "The Beatles (White Album)"

### Exact Matches
Both album titles and artist names that exactly match receive highest scores due to keyword field boost.

### Partial Matches
The folding analyzer enables matching regardless of:
- Case differences ("abbey road" matches "Abbey Road")
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
- Single index query handles both title and artist search efficiently 