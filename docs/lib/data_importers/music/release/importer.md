# DataImporters::Music::Release::Importer

## Summary
Main orchestration class for Music::Release imports from MusicBrainz. This importer coordinates the finder and provider to import all releases for a given album, supporting the multi-item import pattern where one query results in multiple database records.

## Public Methods

### `#call(album:)`
Imports all releases for the specified album from MusicBrainz.
- **Parameters**: `album` (Music::Album) - The album to import releases for
- **Returns**: ImportResult with success/failure status and detailed provider feedback

### `.call(album:)`
Class method for convenient import execution.
- **Parameters**: `album` (Music::Album) - The album to import releases for
- **Returns**: ImportResult with success/failure status and detailed provider feedback

## Private Methods

### `#multi_item_import?`
Indicates this importer supports multi-item imports.
- **Returns**: Boolean - Always returns true for release imports

## Dependencies
- DataImporters::ImporterBase (parent class)
- DataImporters::Music::Release::ImportQuery
- DataImporters::Music::Release::Finder
- DataImporters::Music::Release::Providers::MusicBrainz
- Music::Album model

## Usage Example
```ruby
# Import all releases for an album
album = Music::Album.find_by(title: "The Dark Side of the Moon")
result = DataImporters::Music::Release::Importer.call(album: album)

if result.success?
  puts "Successfully imported #{album.releases.count} releases!"
  puts "Provider results: #{result.provider_results}"
else
  puts "Import failed: #{result.errors.join(', ')}"
end
```

## Import Flow
1. **Query Validation**: Creates and validates ImportQuery with the provided album
2. **Existing Release Check**: Uses Finder to identify already imported releases
3. **MusicBrainz Data Fetch**: Provider searches MusicBrainz for all releases in the album's release group
4. **Release Creation**: Creates new Music::Release records for each MusicBrainz release not already imported
5. **Data Population**: Populates each release with format, country, status, labels, and metadata
6. **Identifier Creation**: Creates MusicBrainz and ASIN identifiers for each release
7. **Result Compilation**: Returns detailed ImportResult with provider feedback

## Multi-Item Import Pattern
This importer implements the multi-item import pattern, which means:
- One query (album) can result in multiple database records (releases)
- The finder doesn't cause early return if existing items are found
- Providers handle the creation and persistence of multiple items
- ImportResult contains feedback for all items processed

## Error Handling
- **Missing Album**: Returns failure if album is not provided or invalid
- **No MusicBrainz ID**: Returns failure if album lacks MusicBrainz release group identifier
- **API Errors**: Gracefully handles MusicBrainz API failures
- **Partial Failures**: Continues processing even if some releases fail to save
- **Validation Errors**: Collects and reports validation errors for individual releases

## Design Decisions
- **Multi-Item Architecture**: Extends ImporterBase with multi-item support for bulk imports
- **Album-Centric**: Requires existing album rather than creating new albums
- **Comprehensive Import**: Imports ALL releases for an album regardless of format or status
- **Incremental Support**: Skips existing releases to enable safe re-imports
- **Detailed Feedback**: Provides comprehensive feedback about what was imported

## Performance Considerations
- **Bulk Processing**: Efficiently processes multiple releases in single operation
- **Duplicate Prevention**: Uses MusicBrainz IDs for precise duplicate detection
- **Database Efficiency**: Minimizes database queries through strategic associations
