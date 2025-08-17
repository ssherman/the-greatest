# DataImporters::Music::Release::ImportQuery

## Summary
Defines the input query for Music::Release imports from MusicBrainz. This query object validates that a valid Music::Album is provided and ensures it has the necessary MusicBrainz release group identifier for importing releases.

## Public Methods

### `#initialize(album:)`
Creates a new import query with the specified album.
- **Parameters**: `album` (Music::Album) - The album to import releases for
- **Returns**: ImportQuery instance

### `#valid?`
Checks if the query is valid for import.
- **Returns**: Boolean - true if album is present, is a Music::Album, and is persisted

### `#validate!`
Validates the query and raises an error if invalid.
- **Raises**: ArgumentError if album is missing, wrong type, or not persisted
- **Returns**: void

### `#album`
Returns the album associated with this query.
- **Returns**: Music::Album - The album to import releases for

## Validations
- `album` - must be present, must be a Music::Album instance, must be persisted in database

## Dependencies
- Music::Album model
- MusicBrainz release group identifier on the album

## Usage Example
```ruby
album = Music::Album.find_by(title: "The Dark Side of the Moon")
query = DataImporters::Music::Release::ImportQuery.new(album: album)

if query.valid?
  result = DataImporters::Music::Release::Importer.call(query)
else
  puts "Invalid query: #{query.errors}"
end
```

## Design Decisions
- **Album-Only Input**: Only requires album parameter to import ALL releases for that album
- **Type Safety**: Validates album type and persistence to prevent runtime errors
- **MusicBrainz Dependency**: Assumes album has MusicBrainz release group identifier for API calls
