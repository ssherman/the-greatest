# DataImporters::Music::Album::ImportQuery

## Summary
Query object that encapsulates parameters for album import operations. Supports either artist+title based imports or MusicBrainz Release Group ID based imports with either/or validation.

## Associations
- None (plain Ruby object)

## Public Methods

### `#initialize(artist: nil, title: nil, release_group_musicbrainz_id: nil, primary_albums_only: false, **options)`
Creates a new ImportQuery instance
- Parameters:
  - `artist` (Music::Artist, nil) — Artist instance for artist+title imports
  - `title` (String, nil) — Album title for artist+title imports
  - `release_group_musicbrainz_id` (String, nil) — MusicBrainz Release Group ID for direct imports
  - `primary_albums_only` (Boolean) — Whether to search only primary albums (default: false)
  - `**options` (Hash) — Additional options stored for future use

### Attribute Readers
- `#artist` - Returns the artist instance
- `#title` - Returns the album title 
- `#release_group_musicbrainz_id` - Returns the MusicBrainz Release Group ID
- `#primary_albums_only` - Returns the primary albums only flag
- `#options` - Returns additional options hash

### Validation Helper Methods
- `#release_group_musicbrainz_id?` - Returns true if release_group_musicbrainz_id is present
- `#artist_and_title?` - Returns true if both artist and title are present

## Validations
- **Either/Or validation**: Requires either (`artist` AND `title`) OR `release_group_musicbrainz_id`
- **Artist presence**: Required unless `release_group_musicbrainz_id` is present
- **Title presence**: Required unless `release_group_musicbrainz_id` is present  
- **Release Group ID presence**: Required unless both `artist` and `title` are present
- **Release Group ID format**: Must be valid UUID format when provided

## Scopes
- None (not an ActiveRecord model)

## Constants
- `UUID_REGEX` - Regular expression for validating MusicBrainz Release Group ID UUID format

## Callbacks
- None

## Dependencies
- ActiveModel::Model for validation functionality
- ActiveModel::Validations for validation methods

## Examples

### Release Group ID Import
```ruby
# Import by MusicBrainz Release Group ID
query = ImportQuery.new(release_group_musicbrainz_id: "6b9a9e04-abd7-4666-86ba-bb220ef4c3b2")
query.valid? # => true
```

### Artist + Title Import
```ruby
# Traditional import by artist and title
artist = Music::Artist.find_by(name: "Pink Floyd")
query = ImportQuery.new(artist: artist, title: "The Wall", primary_albums_only: true)
query.valid? # => true
```

### Invalid Queries
```ruby
# Missing both import methods
query = ImportQuery.new
query.valid? # => false
query.errors.full_messages # => ["Artist can't be blank", "Title can't be blank", "Release group musicbrainz can't be blank"]

# Invalid UUID format  
query = ImportQuery.new(release_group_musicbrainz_id: "not-a-uuid")
query.valid? # => false
query.errors.full_messages # => ["Release group musicbrainz id is invalid"]
```

## Validation Rules
- **Either/or requirement**: Must provide either artist+title OR release_group_musicbrainz_id
- **UUID format validation**: release_group_musicbrainz_id must match UUID pattern when provided
- **Mutual exclusivity**: Cannot provide both import methods simultaneously (validation allows it but import logic uses release_group_musicbrainz_id when both present)

## Usage in Import Pipeline
This query object is used by:
- `DataImporters::Music::Album::Finder` - to determine search strategy
- `DataImporters::Music::Album::Providers::MusicBrainz` - to determine lookup vs search API usage
- `DataImporters::Music::Album::Importer` - as the primary interface for import requests