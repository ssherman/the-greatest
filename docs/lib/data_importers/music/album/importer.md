# DataImporters::Music::Album::Importer

## Summary
Main entry point for importing album data from external sources (currently MusicBrainz). Orchestrates the find-or-create workflow using Finder and Provider classes. Supports both artist+title and MusicBrainz Release Group ID based imports.

## Associations
- Inherits from `DataImporters::ImporterBase`
- Uses `DataImporters::Music::Album::Finder` for existing album detection
- Uses `DataImporters::Music::Album::Providers::MusicBrainz` for data population

## Public Methods

### `::call(artist: nil, release_group_musicbrainz_id: nil, **options)`
Class method that creates and executes an import operation
- Parameters:
  - `artist` (Music::Artist, nil) — Artist instance for artist+title imports
  - `release_group_musicbrainz_id` (String, nil) — MusicBrainz Release Group ID for direct imports
  - `**options` (Hash) — Additional options including `title`, `primary_albums_only`, etc.
- Returns: ImportResult for successful imports, or existing Music::Album for found albums
- Raises: ArgumentError for invalid MusicBrainz Release Group IDs

## Validations
- Delegated to ImportQuery validation

## Scopes
- None (not an ActiveRecord model)

## Constants
- None specific to this class (inherits from ImporterBase)

## Callbacks
- None specific to this class (inherits from ImporterBase)

## Dependencies
- `DataImporters::ImporterBase` — parent class providing import workflow
- `DataImporters::Music::Album::ImportQuery` — query object creation and validation
- `DataImporters::Music::Album::Finder` — existing album detection
- `DataImporters::Music::Album::Providers::MusicBrainz` — data population from MusicBrainz
- `Music::Album` — target model for import

## Import Workflow
1. **Query Creation**: Creates ImportQuery with provided parameters
2. **Validation**: Validates query parameters (either/or validation for import methods)
3. **Finding**: Uses Finder to check for existing albums
4. **Import Decision**: Returns existing album if found, otherwise proceeds with import
5. **Population**: Uses MusicBrainz provider to populate new album with external data
6. **Result**: Returns ImportResult with success/failure status and created album

## Examples

### Release Group ID Import (New)
```ruby
# Import album by MusicBrainz Release Group ID
# Automatically imports/finds artists from MusicBrainz artist-credit data
result = DataImporters::Music::Album::Importer.call(
  release_group_musicbrainz_id: "6b9a9e04-abd7-4666-86ba-bb220ef4c3b2"
)

if result.is_a?(DataImporters::ImportResult)
  if result.success?
    album = result.item
    puts "Imported: #{album.title}"
    puts "Artists: #{album.artists.pluck(:name).join(', ')}"
    puts "Year: #{album.release_year}"
    puts "Genres: #{album.categories.where(category_type: 'genre').pluck(:name).join(', ')}"
  else
    puts "Import failed: #{result.all_errors.join(', ')}"
  end
elsif result.is_a?(Music::Album)
  puts "Found existing album: #{result.title}"
end
```

### Artist + Title Import (Existing)
```ruby
# Traditional import by artist instance and title
artist = Music::Artist.find_by(name: "Pink Floyd")
result = DataImporters::Music::Album::Importer.call(
  artist: artist,
  title: "The Wall",
  primary_albums_only: true
)

if result.is_a?(DataImporters::ImportResult)
  if result.success?
    album = result.item
    puts "Imported: #{album.title}"
  else
    puts "Import failed: #{result.all_errors.join(', ')}"
  end
else
  puts "Found existing album: #{result.title}"
end
```

### Error Handling
```ruby
# Invalid UUID format
begin
  result = DataImporters::Music::Album::Importer.call(
    release_group_musicbrainz_id: "not-a-valid-uuid"
  )
rescue ArgumentError => e
  puts "Invalid UUID: #{e.message}"
end

# Missing required parameters
result = DataImporters::Music::Album::Importer.call
# Returns failed ImportResult with validation errors
```

## Return Value Types
- **ImportResult** - For successful or failed new imports
  - `result.success?` - Boolean indicating success
  - `result.item` - The imported Music::Album (if successful)
  - `result.errors` or `result.all_errors` - Error messages (if failed)
- **Music::Album** - For existing albums found by Finder
  - Direct album instance that was already in the database

## Error Handling
- **Validation Errors**: Invalid query parameters result in failed ImportResult
- **Network Errors**: MusicBrainz API failures result in failed ImportResult  
- **Artist Import Errors**: When using Release Group ID, artist import failures result in failed ImportResult
- **UUID Format Errors**: Invalid Release Group IDs raise ArgumentError

## Import Sources
- **Primary**: MusicBrainz (via MusicBrainz provider)
- **Future**: Extensible to other providers via provider pattern

## Performance Considerations
- Uses Finder to avoid duplicate imports
- MusicBrainz Release Group ID lookup is more efficient than artist+title search
- Artist imports during Release Group ID imports leverage existing artist import system
- Single MusicBrainz API call for Release Group ID imports includes complete data