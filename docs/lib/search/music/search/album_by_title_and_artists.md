# Search::Music::Search::AlbumByTitleAndArtists

## Summary
OpenSearch search class for finding albums by structured title and artists parameters. Designed for high-precision matching to prevent duplicate album imports during list wizard enrichment.

## Purpose
This search class provides structured, high-precision album matching by accepting separate title and artists parameters (rather than free-text search). It's used by the Albums ListItemEnricher to find existing albums in our local database before querying external APIs like MusicBrainz.

## Key Differences from AlbumGeneral
- **Structured parameters**: Accepts `title:` (String) and `artists:` (Array) instead of free text
- **Higher precision**: Default `min_score: 5.0` vs `1.0` in general search
- **Must/should logic**: Title is required (must clause), at least one artist must match (should clause)
- **Deduplication focus**: Optimized for finding exact matches to prevent importing duplicates

## Usage

### Basic Search
```ruby
results = Search::Music::Search::AlbumByTitleAndArtists.call(
  title: "The Dark Side of the Moon",
  artists: ["Pink Floyd"]
)
# Returns: [{id: "123", score: 15.5, source: {...}}]
```

### With Options
```ruby
results = Search::Music::Search::AlbumByTitleAndArtists.call(
  title: "Abbey Road",
  artists: ["The Beatles"],
  size: 1,           # Limit results
  min_score: 8.0     # Higher threshold
)
```

### Multi-Artist Albums
```ruby
results = Search::Music::Search::AlbumByTitleAndArtists.call(
  title: "Watch the Throne",
  artists: ["Jay-Z", "Kanye West"]
)
# Matches if title matches AND at least one artist matches
```

## Public Methods

### `.index_name`
Delegates to `Search::Music::AlbumIndex.index_name`
- Returns: String - The OpenSearch index name for albums

### `.call(title:, artists:, **options)`
Searches for albums matching the given title and artists.

**Parameters:**
- `title` (String, required) - Album title to search for
- `artists` (Array, required) - Array of artist names
- `**options` (Hash, optional):
  - `size` (Integer) - Maximum number of results (default: 10)
  - `from` (Integer) - Result offset for pagination (default: 0)
  - `min_score` (Float) - Minimum relevance score threshold (default: 5.0)

**Returns:**
- Array of hashes with structure: `{id: String, score: Float, source: Hash}`
- Empty array if no matches or validation fails

**Validation:**
- Returns empty array if `title` is blank
- Returns empty array if `artists` is blank, nil, or not an Array
- Skips blank artist names within the array

## Query Structure

### Title Matching (Must Clause)
Title is **required** - at least one title clause must match:
- Phrase match on `title` field (boost: 10.0)
- Keyword exact match on `title.keyword` (boost: 9.0)
- Match all words in `title` field (boost: 8.0)

### Artist Matching (Should Clause)
At least **one artist must match** - creates clauses for each artist:
- Phrase match on `artist_names` field (boost: 6.0)
- Match all words in `artist_names` field (boost: 5.0)

### Minimum Score
Default `min_score: 5.0` ensures high precision:
- Requires at least one high-quality match
- Prevents false positives from low-relevance results
- Can be overridden via options for specific use cases

## Common Use Cases

### Albums List Wizard Enrichment
Primary use case - finding existing albums before MusicBrainz search:
```ruby
def find_local_album(title, artists)
  search_results = ::Search::Music::Search::AlbumByTitleAndArtists.call(
    title: title,
    artists: artists,
    size: 1,
    min_score: 5.0
  )

  return nil if search_results.empty?

  result = search_results.first
  album = ::Music::Album.find_by(id: result[:id].to_i)

  {album: album, score: result[:score]}
end
```

## Performance

### Query Performance
- Typical queries complete in sub-100ms
- Uses existing `Search::Music::AlbumIndex`
- No additional indexing required

### Precision vs Recall
- Optimized for **precision** over recall
- Higher min_score reduces false positives
- Better to miss a match than create an incorrect duplicate

## Dependencies
- `Search::Base::Search` - Base search class
- `Search::Music::AlbumIndex` - Album OpenSearch index
- `Search::Shared::Utils` - Query building utilities

## Related Classes
- `Search::Music::Search::AlbumGeneral` - Free-text album search (lower precision, broader use)
- `Search::Music::Search::AlbumAutocomplete` - Autocomplete album search
- `Services::Lists::Music::Albums::ListItemEnricher` - Primary consumer
- `Search::Music::AlbumIndex` - Index definition with `title` and `artist_names` fields

## Testing
Comprehensive test coverage in `test/lib/search/music/search/album_by_title_and_artists_test.rb`:
- Parameter validation (blank title, artists, non-array)
- Single and multi-artist matching
- Title required, artist required logic
- Min score threshold behavior
- Custom options support
- Result structure verification

## Design Decisions

### Why Separate from AlbumGeneral?
- **Single Responsibility**: Each search class has one clear purpose
- **Clear Interface**: Structured parameters vs free text
- **Different Defaults**: Higher min_score for precision
- **Easier Testing**: No conditional logic based on parameter types

### Why Must/Should Structure?
- **Title Required**: Can't match an album without knowing the title
- **Artist Filtering**: At least one artist must match for confidence
- **Multi-Artist Support**: Any artist match is sufficient for albums with multiple artists
- **Precision**: Prevents artist-only matches with wrong title

### Why Higher Min Score?
- **Deduplication Goal**: Better to miss than create incorrect duplicate
- **Fallback Available**: MusicBrainz catches anything we miss
- **Existing Data Quality**: Our indexed albums are already vetted
- **Configurable**: Can be lowered for specific use cases
