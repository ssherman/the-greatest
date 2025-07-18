# Search::Music::AlbumIndex

## Summary
Manages OpenSearch indexing for Music::Album models. Provides full-text search capabilities for album titles and artist names, enabling users to find albums by title or by the artist who created them.

## Associations
- Indexes `Music::Album` model instances
- Requires eager loading of `:primary_artist` association for indexing

## Public Methods

### `.model_klass`
Returns the model class this index manages
- Returns: Class - Music::Album
- Used by base class for querying and batch operations

### `.model_includes`
Specifies associations to eager load for efficient indexing
- Returns: Array - [:primary_artist]
- Prevents N+1 queries when batch indexing albums

### `.index_definition`
Defines the OpenSearch mapping and settings for album documents
- Returns: Hash - Complete index configuration
- Configures folding analyzer for accent/case-insensitive search
- Maps both `title` and `primary_artist_name` as searchable text fields

## Standard Interface Methods (Inherited)
These methods are inherited from `Search::Base::Index`:

### `.index(album)`
Indexes a single album instance
- Parameters: album (Music::Album) - Album model to index
- Returns: Hash - OpenSearch index response
- Calls `album.as_indexed_json` to get document data

### `.unindex(album)`
Removes an album from the search index
- Parameters: album (Music::Album) - Album model to remove
- Returns: void
- Uses album.id for removal

### `.find(album_id)`
Finds an indexed album document by ID
- Parameters: album_id (Integer) - Album ID to find
- Returns: Hash - Indexed document with album data, or nil if not found

### `.reindex_all`
Rebuilds the entire album index from database
- Returns: void
- Deletes existing index and recreates it
- Includes primary_artist association for efficient processing
- Processes all albums in batches of 1000 for memory efficiency

## Index Structure

### Settings
- **folding analyzer**: Standard tokenizer with lowercase and ASCII folding filters
- Provides accent and case-insensitive search capabilities

### Mappings
- **title**: Album title field
  - Type: text with folding analyzer
  - Keyword subfield: Exact matching with lowercase normalizer
  - Used for: Album title searches, exact title matching

- **primary_artist_name**: Denormalized artist name field
  - Type: text with folding analyzer
  - Keyword subfield: Exact matching with lowercase normalizer
  - Used for: Finding albums by artist name

## Dependencies
- Music::Album - The model being indexed
- Music::Artist - Referenced through primary_artist association
- Search::Base::Index - Base indexing functionality
- OpenSearch folding analyzer - Text analysis for international titles/names

## Usage Examples

```ruby
# Index a single album
album = Music::Album.includes(:primary_artist).find(123)
Search::Music::AlbumIndex.index(album)

# Remove from index
Search::Music::AlbumIndex.unindex(album)

# Find in index
result = Search::Music::AlbumIndex.find(123)
album_title = result["title"] if result
artist_name = result["primary_artist_name"] if result

# Reindex all albums (with efficient loading)
Search::Music::AlbumIndex.reindex_all
```

## Index Name Pattern
Automatically generates index names following the pattern:
- Development: `music_albums_development_[pid]`
- Production: `music_albums_production`
- Test: `music_albums_test_[pid]` (with process ID for parallel tests)

## Data Requirements
Albums must have their `as_indexed_json` method return:
- `title` - The album title
- `primary_artist_name` - The name of the primary artist 