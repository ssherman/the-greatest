# Search::Music::SongIndex

## Summary
Manages OpenSearch indexing for Music::Song models. Provides full-text search capabilities for song titles and artist names, enabling users to find songs by title or by any artist who performed them across multiple albums.

## Associations
- Indexes `Music::Song` model instances
- Requires eager loading of complex association: `albums: :primary_artist`

## Public Methods

### `.model_klass`
Returns the model class this index manages
- Returns: Class - Music::Song
- Used by base class for querying and batch operations

### `.model_includes`
Specifies associations to eager load for efficient indexing
- Returns: Array - [albums: :primary_artist]
- Prevents N+1 queries when accessing song's albums and their artists
- Supports complex association path for artist name extraction

### `.index_definition`
Defines the OpenSearch mapping and settings for song documents
- Returns: Hash - Complete index configuration
- Configures folding analyzer for accent/case-insensitive search
- Maps both `title` and `artist_names` as searchable text fields

## Standard Interface Methods (Inherited)
These methods are inherited from `Search::Base::Index`:

### `.index(song)`
Indexes a single song instance
- Parameters: song (Music::Song) - Song model to index
- Returns: Hash - OpenSearch index response
- Calls `song.as_indexed_json` to get document data

### `.unindex(song)`
Removes a song from the search index
- Parameters: song (Music::Song) - Song model to remove
- Returns: void
- Uses song.id for removal

### `.find(song_id)`
Finds an indexed song document by ID
- Parameters: song_id (Integer) - Song ID to find
- Returns: Hash - Indexed document with song data, or nil if not found

### `.reindex_all`
Rebuilds the entire song index from database
- Returns: void
- Deletes existing index and recreates it
- Includes albums and primary_artist associations for efficient processing
- Processes all songs in batches of 1000 for memory efficiency

## Index Structure

### Settings
- **folding analyzer**: Standard tokenizer with lowercase and ASCII folding filters
- Provides accent and case-insensitive search capabilities

### Mappings
- **title**: Song title field
  - Type: text with folding analyzer
  - Keyword subfield: Exact matching with lowercase normalizer
  - Used for: Song title searches, exact title matching

- **artist_names**: Array of artist names from all albums
  - Type: text with folding analyzer
  - Keyword subfield: Exact matching with lowercase normalizer
  - Used for: Finding songs by any artist who performed them

## Dependencies
- Music::Song - The model being indexed
- Music::Album - Songs belong to albums through many-to-many relationship
- Music::Artist - Referenced through albums' primary_artist association
- Search::Base::Index - Base indexing functionality
- OpenSearch folding analyzer - Text analysis for international titles/names

## Usage Examples

```ruby
# Index a single song
song = Music::Song.includes(albums: :primary_artist).find(123)
Search::Music::SongIndex.index(song)

# Remove from index
Search::Music::SongIndex.unindex(song)

# Find in index
result = Search::Music::SongIndex.find(123)
song_title = result["title"] if result
artist_names = result["artist_names"] if result

# Reindex all songs (with efficient loading)
Search::Music::SongIndex.reindex_all
```

## Index Name Pattern
Automatically generates index names following the pattern:
- Development: `music_songs_development_[pid]`
- Production: `music_songs_production`
- Test: `music_songs_test_[pid]` (with process ID for parallel tests)

## Data Requirements
Songs must have their `as_indexed_json` method return:
- `title` - The song title
- `artist_names` - Array of artist names from all albums this song appears on

## Complex Relationships
Songs can appear on multiple albums, and each album has a primary artist. The song index includes all artist names from all albums the song appears on, making it searchable by any associated artist. 