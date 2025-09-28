# DataImporters::Music::Album::BulkImporter

## Summary
Handles bulk album discovery and import for a given artist from MusicBrainz. This class operates outside the standard ImporterBase framework to simplify bulk operations and delegates individual album imports to the regular Album::Importer.

## Associations
- Uses `::Music::Artist` model (requires MusicBrainz ID)
- Creates multiple `::Music::Album` records via delegation to Album::Importer
- No direct associations inside this class

## Public Methods

### `.call(artist:, primary_albums_only: false)`
Class method for bulk album discovery and import
- Parameters:
  - `artist` (Music::Artist) — Artist with MusicBrainz ID required
  - `primary_albums_only` (Boolean) — Whether to import only primary albums (default: false)
- Returns: ImportResult with aggregated results from all album imports
- Side effects: Creates multiple albums via Album::Importer delegation

### `#initialize(artist:, primary_albums_only: false)`
Creates new bulk importer instance
- Parameters: Same as `.call`
- Initializes MusicBrainz search service

### `#call`
Executes the bulk import workflow
- Returns: ImportResult with first imported album as main item, all albums in `items` array
- Side effects: Calls Album::Importer for each found album

## Validations
- Artist must have MusicBrainz ID for bulk import
- Delegates individual album validation to Album::Importer

## Scopes
- None

## Constants
- None

## Callbacks
- None

## Dependencies
- `::Music::Musicbrainz::Search::ReleaseGroupSearch` — MusicBrainz API search
- `DataImporters::Music::Album::Importer` — Individual album import delegation
- `DataImporters::ImportResult` — Result aggregation
- `DataImporters::ProviderResult` — Error handling

## Architecture Decision

### Separation from ImporterBase
This class intentionally **does not inherit from ImporterBase** because:
- Bulk discovery is fundamentally different from single-item import
- Avoids forcing bulk operations into the single-item provider framework
- Simplifies the implementation by directly calling MusicBrainz API
- Delegates actual album creation to the established single Album::Importer

### Workflow
1. **Validate Prerequisites**: Artist must have MusicBrainz ID
2. **API Discovery**: Call MusicBrainz directly to find all albums
3. **Delegate Creation**: Use Album::Importer for each found album
4. **Aggregate Results**: Combine all individual import results

## Error Handling
- **Missing MusicBrainz ID**: Returns failure result with clear error message
- **MusicBrainz API errors**: Returns failure result with API error details
- **No albums found**: Returns failure result (different from single album import)
- **Individual album failures**: Continues processing, aggregates all results
- **Exceptions**: Caught and returned as failure results

## Usage Examples

### Basic Bulk Import
```ruby
# Import all albums for an artist
artist = Music::Artist.find_by(name: "Pink Floyd")
result = DataImporters::Music::Album::BulkImporter.call(artist: artist)

if result.success?
  puts "Imported #{result.items.count} albums"
  result.items.each { |album| puts "- #{album.title}" }
end
```

### Primary Albums Only
```ruby
# Import only primary albums (excludes compilations, live albums, etc.)
result = DataImporters::Music::Album::BulkImporter.call(
  artist: artist,
  primary_albums_only: true
)
```

### Collaborative Albums Handling
```ruby
# When importing albums for multiple artists, existing albums are enriched
# Example: Import albums for each member of a supergroup
supergroup_members = ["David Bowie", "Freddie Mercury", "Annie Lennox"]

supergroup_members.each do |artist_name|
  artist = Music::Artist.find_by(name: artist_name)
  result = DataImporters::Music::Album::BulkImporter.call(artist: artist)
  
  # Existing collaborative albums will:
  # 1. Add this artist to their artist associations
  # 2. Re-run all providers (AI descriptions, Amazon data, etc.)
  # 3. Update with any new data from this artist's perspective
end
```

## Relationship to Album::Importer

### Clear Separation of Concerns
- **BulkImporter**: Discovers multiple albums from MusicBrainz for an artist
- **Album::Importer**: Handles single album import with full provider chain

### Integration Pattern
```ruby
# BulkImporter delegates to Album::Importer for each found album
# Passes artist and force_providers to handle collaborative albums correctly
result = DataImporters::Music::Album::Importer.call(
  release_group_musicbrainz_id: album_mbid,
  artist: @artist,
  force_providers: true
)
```

This ensures:
- **Consistent album creation logic** for new albums
- **Collaborative album support**: Existing albums get additional artist associations
- **Full provider enrichment**: All providers run even on existing albums (AI descriptions, Amazon data)
- **Proper validation and error handling** through single Album::Importer
- **Incremental saving** after each successful provider

## Performance Considerations
- **Sequential Processing**: Albums imported one at a time for reliability
- **Early Termination**: Continues on individual failures, doesn't stop bulk operation
- **Memory Efficiency**: Doesn't load all albums into memory simultaneously
- **API Efficiency**: Single MusicBrainz call for discovery, then individual imports

## Testing
Comprehensive test coverage is provided in `test/lib/data_importers/music/album/bulk_importer_test.rb`:
- **Success Scenarios**: Multiple album discovery and import
- **Error Handling**: Missing MusicBrainz ID, API failures, no albums found
- **Partial Failures**: Some albums succeed, others fail
- **API Stubbing**: Uses Mocha to mock MusicBrainz API calls and Album::Importer delegation
- **Result Object Testing**: BulkImportResult behavior and album filtering

## Future Enhancements
- **Parallel Processing**: Could use background jobs for large album sets
- **Progress Tracking**: Could provide progress callbacks for long operations
- **Filtering Options**: Could add genre, year, or other filtering criteria
- **Incremental Updates**: Could skip albums that haven't changed since last import
