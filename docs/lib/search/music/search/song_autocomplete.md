# Search::Music::Search::SongAutocomplete

## Summary
Dedicated search class for song autocomplete functionality. Uses edge n-gram analysis for partial string matching on song titles. Optimized for search-as-you-type UX with lower minimum score threshold than general search.

## Purpose
Provides fast, partial-match search results for autocomplete dropdowns. Separate from `SongGeneral` to allow different scoring strategies and field weighting for autocomplete vs full search. Will be used in future song admin interface.

## Class Methods

### `.call(text, options = {})`
Executes autocomplete search query.
- Parameters:
  - `text` (String) - Search query text
  - `options` (Hash) - Optional search parameters
    - `:min_score` (Float) - Minimum relevance score. Default: `0.1` (much lower than general search)
    - `:size` (Integer) - Maximum results to return. Default: `20`
    - `:from` (Integer) - Offset for pagination. Default: `0`
- Returns: Array of hashes with `:id` and `:score` keys
- Returns empty array if text is blank

### `.build_query_definition(text, min_score, size, from)`
Constructs OpenSearch query with autocomplete-specific boosting.
- Uses three search strategies with different boosts:
  1. `title.autocomplete` field (boost: 10.0) - Edge n-gram matching
  2. `title` match_phrase (boost: 8.0) - Exact phrase matching
  3. `title.keyword` term (boost: 6.0) - Exact keyword matching
- Returns: Hash with OpenSearch query structure

## Index Configuration

Requires `title.autocomplete` field with:
- **Analyzer**: `autocomplete` (edge_ngram filter with min_gram: 3, max_gram: 20)
- **Search Analyzer**: `autocomplete_search` (no edge_ngram, prevents double-tokenization)

## Query Strategy

```json
{
  "bool": {
    "should": [
      {"match": {"title.autocomplete": "query", "boost": 10.0}},
      {"match_phrase": {"title": "query", "boost": 8.0}},
      {"term": {"title.keyword": "query", "boost": 6.0}}
    ],
    "minimum_should_match": 1
  }
}
```

## Differences from SongGeneral

| Aspect | SongAutocomplete | SongGeneral |
|--------|------------------|-------------|
| Min Score | 0.1 (lenient) | Higher (strict) |
| Primary Field | title.autocomplete (edge n-grams) | title (standard) |
| Use Case | As-you-type search | Full search results |
| Partial Matching | Yes (via edge n-grams) | Limited |

## Dependencies
- `Search::Music::SongIndex` - Index definition with autocomplete analyzer
- `Search::Base::Search` - Base search functionality
- `Search::Shared::Utils` - Query building utilities

## Usage Example

```ruby
# In controller (when song admin is implemented)
results = Search::Music::Search::SongAutocomplete.call("bohemian", size: 5)
# => [{id: "123", score: 5.2}, {id: "456", score: 3.1}]

song_ids = results.map { |r| r[:id].to_i }
songs = Music::Song.where(id: song_ids)
                   .includes(:artists, :albums)
                   .in_order_of(:id, song_ids)

# Format for autocomplete dropdown
json = songs.map { |s|
  {
    value: s.id,
    text: "#{s.title} - #{s.artists.map(&:name).join(", ")}"
  }
}
```

## Performance Notes
- Edge n-grams increase index size but dramatically improve autocomplete UX
- Lower min_score allows more fuzzy matching
- Typically used with result limits of 10-20 for dropdown display
- Controller should eager load artists and albums for display formatting

## Status
**Not yet in use** - Will be implemented when song admin interface (Phase 4) is built. Index already configured with autocomplete field.
