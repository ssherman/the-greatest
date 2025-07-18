# Search::Music::Search::ArtistGeneral

## Summary
Executes general full-text search queries against the artist index. Provides relevance-ranked results for artist name searches with support for exact matches, phrase matching, and fuzzy matching.

## Public Methods

### `.index_name`
Returns the name of the index to search
- Returns: String - Delegates to Search::Music::ArtistIndex.index_name
- Ensures search queries target the same index used for indexing

### `.call(text, options = {})`
Performs a general search for artists by name
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
- `name` - Artist name (analyzed text)
- `name.keyword` - Artist name (exact keyword)

### Boost Values
- **Exact match**: 10.0x boost for keyword field matches
- **Phrase match**: 5.0x boost for exact phrase in analyzed text
- **Fuzzy match**: 1.0x boost for standard text matching

### Result Format
Each result contains:
- `:id` - String representation of artist ID
- `:score` - Float relevance score from OpenSearch
- `:source` - Hash of indexed document data (name, etc.)

## Dependencies
- Search::Base::Search - Base search functionality
- Search::Music::ArtistIndex - For index name and targeting
- Search::Shared::Utils - For query building utilities

## Usage Examples

```ruby
# Basic search
results = Search::Music::Search::ArtistGeneral.call("Beatles")
# Returns artists matching "Beatles" ordered by relevance

# Search with options
results = Search::Music::Search::ArtistGeneral.call("John", {
  size: 5,
  min_score: 2.0,
  from: 10
})

# Process results
results.each do |result|
  artist_id = result[:id].to_i
  relevance = result[:score]
  artist_name = result[:source]["name"]
  puts "#{artist_name} (ID: #{artist_id}, Score: #{relevance})"
end
```

## Search Behavior

### Exact Matches
Artist names that exactly match the query receive highest scores due to keyword field boost.

### Partial Matches
The folding analyzer enables matching regardless of:
- Case differences ("beatles" matches "Beatles")
- Accent differences ("naïve" matches "naive")
- Common character variations

### Empty Results
- Returns empty array for blank/nil input
- Returns empty array when no matches meet min_score threshold
- Gracefully handles OpenSearch connection errors

## Performance Considerations
- Uses multi-match "most_fields" for comprehensive relevance scoring
- Configurable result limits prevent oversized responses
- Min_score filtering reduces irrelevant results 