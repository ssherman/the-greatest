# DataImporters::Music::Album::Importer

## Summary
Main entry point for importing **single album** data from external sources including MusicBrainz, Amazon Product API, and AI Description generation. Orchestrates the find-or-create workflow using Finder and Provider classes. Supports query-based imports (artist+title, MusicBrainz Release Group ID) and item-based imports for enriching existing albums.

**Note**: For bulk album discovery operations, use `DataImporters::Music::Album::BulkImporter` instead.

## Associations
- Inherits from `DataImporters::ImporterBase`
- Uses `DataImporters::Music::Album::Finder` for existing album detection
- Uses `DataImporters::Music::Album::Providers::MusicBrainz` for MusicBrainz data population
- Uses `DataImporters::Music::Album::Providers::Amazon` for Amazon Product API integration
- Uses `DataImporters::Music::Album::Providers::AiDescription` for AI-generated album descriptions

## Public Methods

### `::call(artist: nil, release_group_musicbrainz_id: nil, item: nil, force_providers: false, providers: nil, **options)`
Class method that creates and executes an import operation supporting both query-based and item-based imports
- Parameters:
  - `artist` (Music::Artist, nil) — Artist instance for artist+title query-based imports
  - `release_group_musicbrainz_id` (String, nil) — MusicBrainz Release Group ID for query-based imports
  - `item` (Music::Album, nil) — Existing album instance for item-based imports (enrichment)
  - `force_providers` (Boolean) — Run providers even if existing record found (default: false)
  - `providers` (Array, nil) — Specific provider names to run (e.g., [:amazon, :music_brainz])
  - `**options` (Hash) — Additional options including `title`, `primary_albums_only`, etc.
- Returns: ImportResult with success status, item, and provider results
- Raises: ArgumentError for invalid parameters or MusicBrainz Release Group IDs

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
- `DataImporters::Music::Album::Providers::Amazon` — asynchronous Amazon Product API integration
- `DataImporters::Music::Album::Providers::AiDescription` — asynchronous AI-generated album descriptions
- `Music::Album` — target model for import

## Import Workflow

### Query-Based Import (Traditional)
1. **Query Creation**: Creates ImportQuery with provided parameters (artist+title or MusicBrainz ID)
2. **Validation**: Validates query parameters (either/or validation for import methods)
3. **Finding**: Uses Finder to check for existing albums
4. **Import Decision**: Returns existing album if found (unless force_providers is true)
5. **Population**: Runs providers (MusicBrainz and Amazon) to populate new album with external data
6. **Result**: Returns ImportResult with success/failure status and created album

### Item-Based Import (Enrichment)
1. **Item Validation**: Uses provided album instance directly
2. **Provider Execution**: Runs all providers or filtered subset to enrich existing data
3. **Population**: MusicBrainz provider may update existing data, Amazon provider adds external links and images
4. **Result**: Returns ImportResult with success/failure status and enriched album

## Examples

### Query-Based Import: Release Group ID
```ruby
# Import album by MusicBrainz Release Group ID
# Automatically imports/finds artists from MusicBrainz artist-credit data
result = DataImporters::Music::Album::Importer.call(
  release_group_musicbrainz_id: "6b9a9e04-abd7-4666-86ba-bb220ef4c3b2"
)

if result.success?
  album = result.item
  puts "Imported: #{album.title}"
  puts "Artists: #{album.artists.pluck(:name).join(', ')}"
  puts "Year: #{album.release_year}"
  puts "Genres: #{album.categories.where(category_type: 'genre').pluck(:name).join(', ')}"
else
  puts "Import failed: #{result.all_errors.join(', ')}"
end
```

### Query-Based Import: Artist + Title
```ruby
# Traditional import by artist instance and title
artist = Music::Artist.find_by(name: "Pink Floyd")
result = DataImporters::Music::Album::Importer.call(
  artist: artist,
  title: "The Wall",
  primary_albums_only: true
)

if result.success?
  album = result.item
  puts "Imported: #{album.title}"
  puts "Amazon links: #{album.external_links.amazon.count}"
else
  puts "Import failed: #{result.all_errors.join(', ')}"
end
```

### Item-Based Import: Enrich Existing Album
```ruby
# Enrich existing album with all providers
existing_album = Music::Album.find_by(title: "The Dark Side of the Moon")
result = DataImporters::Music::Album::Importer.call(
  item: existing_album
)

if result.success?
  puts "Enriched: #{result.item.title}"
  puts "Amazon links added: #{result.item.external_links.amazon.count}"
  puts "Has primary image: #{result.item.images.where(primary: true).exists?}"
else
  puts "Enrichment failed: #{result.all_errors.join(', ')}"
end
```

### Item-Based Import: Selective Provider Execution
```ruby
# Enrich existing album with only Amazon provider
existing_album = Music::Album.find_by(title: "Wish You Were Here")
result = DataImporters::Music::Album::Importer.call(
  item: existing_album,
  providers: [:amazon]
)

if result.success?
  puts "Amazon enrichment completed"
  amazon_results = result.provider_results.select { |r| r.provider_name.include?("Amazon") }
  puts "Amazon provider success: #{amazon_results.first&.success?}"
else
  puts "Amazon enrichment failed: #{result.all_errors.join(', ')}"
end
```

### Force Provider Execution
```ruby
# Re-run providers even if album already exists
artist = Music::Artist.find_by(name: "Pink Floyd")
result = DataImporters::Music::Album::Importer.call(
  artist: artist,
  title: "The Wall",
  force_providers: true
)

puts "Re-enriched existing album with fresh data"
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
- **ImportResult** - For all import operations (both query-based and item-based)
  - `result.success?` - Boolean indicating overall success (any provider succeeded)
  - `result.item` - The imported or enriched Music::Album
  - `result.provider_results` - Array of individual provider results
  - `result.errors` or `result.all_errors` - Error messages (if failed)

## Error Handling
- **Parameter Validation**: Must provide exactly one of `query` parameters or `item` parameter
- **Query Validation**: Invalid query parameters (missing artist/MusicBrainz ID) result in failed ImportResult
- **UUID Format Errors**: Invalid Release Group IDs raise ArgumentError
- **Network Errors**: MusicBrainz and Amazon API failures result in failed ImportResult
- **Artist Import Errors**: When using Release Group ID, artist import failures result in failed ImportResult
- **Amazon API Errors**: Missing credentials or API failures are handled gracefully (provider fails but import continues)
- **Provider Errors**: Individual provider failures don't stop other providers from running

## Import Sources
- **MusicBrainz**: Primary music metadata (artists, albums, genres, release dates)
- **Amazon Product API**: Commercial product data, pricing, external purchase links, album artwork
- **AI Description Service**: AI-generated album descriptions via background job
- **MusicBrainz Cover Art Archive**: High-quality album artwork (via background job)

## Provider Philosophy
All providers operate as **enhancement services** rather than **validation gates**:
- MusicBrainz "not found" returns success with empty data (allows album creation with basic info)
- Amazon and AI Description providers queue background jobs asynchronously
- Individual provider failures don't prevent album creation or other providers from running
- Items are saved incrementally after each successful provider

## Performance Considerations
- **Query-Based**: Uses Finder to avoid duplicate imports
- **Item-Based**: Skips search operations for faster enrichment workflows
- **Provider Filtering**: Run only specific providers to reduce processing time
- **Async Processing**: Amazon provider launches background job for non-blocking operation
- **Selective Updates**: Providers only update relevant data (Amazon skips if images exist)
- **MusicBrainz Efficiency**: Release Group ID lookup more efficient than artist+title search
- **Artist Import Reuse**: Leverages existing artist import system for consistency