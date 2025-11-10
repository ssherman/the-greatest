# Search::Music::Search::ArtistAutocomplete

## Summary
Dedicated search class for artist autocomplete functionality. Uses edge n-gram analysis for partial string matching (e.g., typing "depe" matches "Depeche Mode"). Optimized for search-as-you-type UX with lower minimum score threshold than general search.

## Purpose
Provides fast, partial-match search results for autocomplete dropdowns. Separate from `ArtistGeneral` to allow different scoring strategies and field weighting for autocomplete vs full search.

## Class Methods

### `.call(text, options = {})`
Executes autocomplete search query.
- Parameters:
  - `text` (String) - Search query text
  - `options` (Hash) - Optional search parameters
    - `:min_score` (Float) - Minimum relevance score. Default: `0.1` (much lower than general search)
    - `:size` (Integer) - Maximum results to return. Default: `10`
    - `:from` (Integer) - Offset for pagination. Default: `0`
- Returns: Array of hashes with `:id` and `:score` keys
- Returns empty array if text is blank

### `.build_query_definition(text, min_score, size, from)`
Constructs OpenSearch query with autocomplete-specific boosting.
- Uses three search strategies with different boosts:
  1. `name.autocomplete` field (boost: 10.0) - Edge n-gram matching
  2. `name` match_phrase (boost: 8.0) - Exact phrase matching
  3. `name.keyword` term (boost: 6.0) - Exact keyword matching
- Returns: Hash with OpenSearch query structure

## Index Configuration

Requires `name.autocomplete` field with:
- **Analyzer**: `autocomplete` (edge_ngram filter with min_gram: 3, max_gram: 20)
- **Search Analyzer**: `autocomplete_search` (no edge_ngram, prevents double-tokenization)

## Query Strategy

```json
{
  "bool": {
    "should": [
      {"match": {"name.autocomplete": "query", "boost": 10.0}},
      {"match_phrase": {"name": "query", "boost": 8.0}},
      {"term": {"name.keyword": "query", "boost": 6.0}}
    ],
    "minimum_should_match": 1
  }
}
```

## Differences from ArtistGeneral

| Aspect | ArtistAutocomplete | ArtistGeneral |
|--------|-------------------|---------------|
| Min Score | 0.1 (lenient) | 1.0 (strict) |
| Primary Field | name.autocomplete (edge n-grams) | name (standard) |
| Use Case | As-you-type search | Full search results |
| Partial Matching | Yes (via edge n-grams) | Limited |

## Dependencies
- `Search::Music::ArtistIndex` - Index definition with autocomplete analyzer
- `Search::Base::Search` - Base search functionality
- `Search::Shared::Utils` - Query building utilities

## Usage Example

```ruby
# In controller
results = Search::Music::Search::ArtistAutocomplete.call("depe", size: 5)
# => [{id: "123", score: 5.2}, {id: "456", score: 3.1}]

artist_ids = results.map { |r| r[:id].to_i }
artists = Music::Artist.where(id: artist_ids).in_order_of(:id, artist_ids)
```

## Performance Notes
- Edge n-grams increase index size but dramatically improve autocomplete UX
- Lower min_score allows more fuzzy matching
- Typically used with small result limits (5-10) for dropdown display
