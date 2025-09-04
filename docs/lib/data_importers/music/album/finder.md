# DataImporters::Music::Album::Finder

## Summary
Finds existing albums in the database using multiple strategies to avoid duplicate imports. Supports both MusicBrainz ID-based lookups and artist+title matching strategies. Prioritizes MusicBrainz identifiers over title matching for better accuracy.

## Associations
- Uses `::Music::Album` model for database queries
- Uses `::Music::Musicbrainz::Search::ReleaseGroupSearch` for external data validation

## Public Methods

### `#call(query:)`
Main method to find existing albums based on query parameters
- Parameters:
  - `query` (ImportQuery) — Query with either `release_group_musicbrainz_id` OR (`artist` + `title`)
- Returns: Music::Album instance if found, nil if not found
- Strategy: Uses MusicBrainz ID lookup when available, falls back to artist+title search

## Validations
- None (finder operation, doesn't create/modify data)

## Scopes
- None (uses dynamic queries)

## Constants
- None

## Callbacks
- None

## Dependencies
- `::Music::Album` — target model for database queries
- `::Music::Musicbrainz::Search::ReleaseGroupSearch` — for MusicBrainz data validation during artist+title searches
- `DataImporters::Music::Album::ImportQuery` — query object interface

## Private Methods

### `#find_by_musicbrainz_id_only(mbid)`
Finds album by MusicBrainz Release Group identifier only
- Parameters: mbid (String) — MusicBrainz Release Group ID
- Returns: Music::Album or nil
- Used for Release Group ID-based queries

### `#find_by_musicbrainz_id(mbid)`
Finds album by MusicBrainz Release Group identifier from search results
- Parameters: mbid (String) — MusicBrainz Release Group ID  
- Returns: Music::Album or nil
- Used during artist+title searches to check MusicBrainz search results

### `#find_by_title(artist, title)`
Finds album by exact title match within artist's albums
- Parameters: artist (Music::Artist), title (String)
- Returns: Music::Album or nil
- Fallback method when MusicBrainz search fails or returns no results

### `#get_artist_musicbrainz_id(artist)`
Retrieves MusicBrainz artist ID from artist's identifiers
- Parameters: artist (Music::Artist)
- Returns: String (MBID) or nil

### `#search_service`
Lazily instantiates MusicBrainz search service
- Returns: Music::Musicbrainz::Search::ReleaseGroupSearch instance

## Search Strategies

### 1. MusicBrainz Release Group ID Priority
When `release_group_musicbrainz_id` is provided:
- Directly searches database for existing album with that MusicBrainz identifier
- No external API calls needed
- Most accurate method for existing album detection

### 2. Artist + Title with MusicBrainz Validation
When `artist` and `title` are provided:
1. **MusicBrainz Search**: Queries MusicBrainz API for release groups by artist MBID and title
2. **MBID Lookup**: Checks if any search results already exist in database by MusicBrainz ID
3. **Title Fallback**: If no MusicBrainz results or no MBID matches, searches by exact title within artist's albums

### 3. Primary Albums Only Support
Supports `primary_albums_only` flag for filtering search results to official studio albums only.

## Examples

### Release Group ID Lookup
```ruby
query = ImportQuery.new(release_group_musicbrainz_id: "6b9a9e04-abd7-4666-86ba-bb220ef4c3b2")
finder = DataImporters::Music::Album::Finder.new
result = finder.call(query: query)

if result
  puts "Found existing album: #{result.title}"
else
  puts "Album not found in database"
end
```

### Artist + Title Search
```ruby
artist = Music::Artist.find_by(name: "Pink Floyd")
query = ImportQuery.new(artist: artist, title: "The Wall")
finder = DataImporters::Music::Album::Finder.new
result = finder.call(query: query)

if result
  puts "Found existing album: #{result.title}"
  puts "Found via: #{result.identifiers.pluck(:identifier_type, :value)}"
else
  puts "Album not found, proceed with import"
end
```

### Primary Albums Only
```ruby
artist = Music::Artist.find_by(name: "Pink Floyd")
query = ImportQuery.new(artist: artist, primary_albums_only: true)
finder = DataImporters::Music::Album::Finder.new
result = finder.call(query: query)
# Searches only official studio albums, not compilations or live albums
```

## Search Priority
1. **MusicBrainz Release Group ID** (when provided) - Highest accuracy
2. **MusicBrainz Search Results** (during artist+title search) - Good accuracy via external validation
3. **Exact Title Match** (fallback) - Lower accuracy but catches edge cases

## Error Handling
- **Missing Artist MusicBrainz ID**: Returns nil (cannot search MusicBrainz without artist MBID)
- **MusicBrainz API Errors**: Logs warning, falls back to title matching
- **Invalid Queries**: Returns nil for queries missing both search methods

## Performance Considerations
- **Database-first approach**: Always checks database before external API calls
- **Lazy search service**: Only instantiates MusicBrainz search service when needed
- **Efficient queries**: Uses database indexes on identifiers and album-artist relationships
- **Graceful degradation**: Falls back to simpler methods if complex methods fail

## Integration
Used by `DataImporters::Music::Album::Importer` as the first step in the import workflow to prevent duplicate albums.