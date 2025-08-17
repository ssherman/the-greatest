# DataImporters::Music::Release::Finder

## Summary
Responsible for finding existing Music::Release records that match MusicBrainz releases. This finder searches for releases by their MusicBrainz release ID to prevent duplicate imports and enable incremental updates.

## Public Methods

### `#call(query)`
Finds existing releases for the given import query.
- **Parameters**: `query` (ImportQuery) - The import query containing the album
- **Returns**: Array of Music::Release records that already exist, or empty array if none found

## Private Methods

### `#get_release_group_mbid(album)`
Extracts the MusicBrainz release group MBID from the album's identifiers.
- **Parameters**: `album` (Music::Album) - The album to get MBID for
- **Returns**: String - The release group MBID, or nil if not found

### `#find_existing_release(release_mbid, album)`
Finds an existing release by its MusicBrainz release ID.
- **Parameters**: 
  - `release_mbid` (String) - The MusicBrainz release ID
  - `album` (Music::Album) - The album to search within
- **Returns**: Music::Release or nil - The existing release if found

## Dependencies
- Music::Musicbrainz::Search::ReleaseSearch service
- Music::Album model with MusicBrainz identifiers
- Music::Release model with identifier associations

## Usage Example
```ruby
album = Music::Album.find_by(title: "The Dark Side of the Moon")
query = DataImporters::Music::Release::ImportQuery.new(album: album)
finder = DataImporters::Music::Release::Finder.new

existing_releases = finder.call(query)
puts "Found #{existing_releases.count} existing releases"
```

## Design Decisions
- **MusicBrainz ID Matching**: Uses MusicBrainz release IDs for precise duplicate detection
- **Album-Scoped Search**: Only searches within the specified album's releases
- **Error Handling**: Gracefully handles MusicBrainz API errors and missing data
- **Incremental Support**: Enables partial imports by skipping existing releases

## Error Handling
- Returns empty array if MusicBrainz search fails
- Logs warnings for API errors
- Continues processing even if individual releases can't be found
