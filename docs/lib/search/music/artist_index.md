# Search::Music::ArtistIndex

## Summary
Manages OpenSearch indexing for Music::Artist models. Provides full-text search capabilities for artist names using the folding analyzer for accent-insensitive matching.

## Associations
- Indexes `Music::Artist` model instances
- No direct associations (inherits interface from base class)

## Public Methods

### `.model_klass`
Returns the model class this index manages
- Returns: Class - Music::Artist
- Used by base class for querying and batch operations

### `.index_definition`
Defines the OpenSearch mapping and settings for artist documents
- Returns: Hash - Complete index configuration
- Configures folding analyzer for accent/case-insensitive search
- Maps `name` field as both analyzed text and exact keyword

## Standard Interface Methods (Inherited)
These methods are inherited from `Search::Base::Index`:

### `.index(artist)`
Indexes a single artist instance
- Parameters: artist (Music::Artist) - Artist model to index
- Returns: Hash - OpenSearch index response
- Calls `artist.as_indexed_json` to get document data

### `.unindex(artist)`
Removes an artist from the search index
- Parameters: artist (Music::Artist) - Artist model to remove
- Returns: void
- Uses artist.id for removal

### `.find(artist_id)`
Finds an indexed artist document by ID
- Parameters: artist_id (Integer) - Artist ID to find
- Returns: Hash - Indexed document with artist data, or nil if not found

### `.reindex_all`
Rebuilds the entire artist index from database
- Returns: void
- Deletes existing index and recreates it
- Processes all artists in batches of 1000 for memory efficiency

## Index Structure

### Settings
- **folding analyzer**: Standard tokenizer with lowercase and ASCII folding filters
- Provides accent and case-insensitive search capabilities

### Mappings
- **name**: Main searchable field
  - Type: text with folding analyzer
  - Keyword subfield: Exact matching with lowercase normalizer
  - Used for: Artist name searches, exact name matching

## Dependencies
- Music::Artist - The model being indexed
- Search::Base::Index - Base indexing functionality
- OpenSearch folding analyzer - Text analysis for international names

## Usage Examples

```ruby
# Index a single artist
artist = Music::Artist.find(123)
Search::Music::ArtistIndex.index(artist)

# Remove from index
Search::Music::ArtistIndex.unindex(artist)

# Find in index
result = Search::Music::ArtistIndex.find(123)
artist_name = result["name"] if result

# Reindex all artists
Search::Music::ArtistIndex.reindex_all
```

## Index Name Pattern
Automatically generates index names following the pattern:
- Development: `music_artists_development_[pid]`
- Production: `music_artists_production`
- Test: `music_artists_test_[pid]` (with process ID for parallel tests) 