# Search::Shared::Utils

## Summary
Utility methods for text processing and OpenSearch query building. Provides common functionality for cleaning text data and constructing various types of OpenSearch queries.

## Public Methods

### `.cleanup_for_indexing(text_array)`
Cleans and normalizes an array of text values for indexing
- Parameters: text_array (Array) - Array of text values to clean
- Returns: Array - Cleaned text values with special characters removed
- **NEW (Nov 2025)**: Normalizes Unicode smart quotes to ASCII straight quotes via `Services::Text::QuoteNormalizer`
- Removes special characters, normalizes whitespace, filters out blanks
- Used when preparing data for indexing

### `.normalize_search_text(text)`
Normalizes search text for consistent querying
- Parameters: text (String) - Raw search text from user input
- Returns: String - Normalized text ready for search queries
- **NEW (Nov 2025)**: Normalizes Unicode smart quotes to ASCII straight quotes via `Services::Text::QuoteNormalizer`
- Converts to lowercase, removes special characters, normalizes whitespace

### `.build_match_query(field, query, boost: 1.0, operator: "or")`
Builds an OpenSearch match query for a single field
- Parameters:
  - field (String) - Field name to search
  - query (String) - Search text
  - boost (Float) - Relevance boost multiplier (default: 1.0)
  - operator (String) - Query operator "and" or "or" (default: "or")
- Returns: Hash - OpenSearch match query structure
- Used for basic text matching with optional relevance boosting

### `.build_match_phrase_query(field, query, boost: 1.0)`
Builds an OpenSearch match_phrase query for exact phrase matching
- Parameters:
  - field (String) - Field name to search
  - query (String) - Phrase to match exactly
  - boost (Float) - Relevance boost multiplier (default: 1.0)
- Returns: Hash - OpenSearch match_phrase query structure
- Used when exact phrase order matters

### `.build_term_query(field, value, boost: 1.0)`
Builds an OpenSearch term query for exact value matching
- Parameters:
  - field (String) - Field name (typically keyword field)
  - value (String) - Exact value to match
  - boost (Float) - Relevance boost multiplier (default: 1.0)
- Returns: Hash - OpenSearch term query structure
- Used for exact matching on keyword/numeric fields

### `.build_bool_query(must: [], should: [], must_not: [], filter: [], minimum_should_match: nil)`
Builds a complex OpenSearch bool query combining multiple conditions
- Parameters:
  - must (Array) - Queries that must match (default: [])
  - should (Array) - Queries that should match for boosting (default: [])
  - must_not (Array) - Queries that must not match (default: [])
  - filter (Array) - Filtering queries (no scoring) (default: [])
  - minimum_should_match (Integer) - Minimum should clauses to match
- Returns: Hash - OpenSearch bool query structure
- Core building block for complex search logic

## Constants
None

## Dependencies
- `Services::Text::QuoteNormalizer` - For Unicode quote normalization (Nov 2025)
- Date/DateTime/Time - For date parsing operations
- String manipulation methods

## Usage Pattern
Used throughout search classes for query construction:

```ruby
# Text normalization
clean_query = Search::Shared::Utils.normalize_search_text(user_input)

# Query building
match_query = Search::Shared::Utils.build_match_query("name", clean_query, boost: 2.0)
phrase_query = Search::Shared::Utils.build_match_phrase_query("title", clean_query, boost: 5.0)

# Complex queries
bool_query = Search::Shared::Utils.build_bool_query(
  should: [match_query, phrase_query],
  minimum_should_match: 1
)
```

## Text Processing
All text processing methods handle edge cases:
- Blank/nil input returns appropriate empty values
- Special characters are removed or normalized consistently
- Whitespace is collapsed and trimmed 