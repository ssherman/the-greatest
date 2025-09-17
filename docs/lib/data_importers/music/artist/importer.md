# DataImporters::Music::Artist::Importer

## Summary
Main orchestration class for Music::Artist imports from external sources. Coordinates finder and providers to import artists by name or MusicBrainz ID, with support for provider re-execution.

## Public Methods

### `.call(name: nil, musicbrainz_id: nil, force_providers: false, **options)`
Main entry point for artist imports
- Parameters:
  - name (String, optional) - Artist name to search for
  - musicbrainz_id (String, optional) - MusicBrainz artist ID for direct lookup
  - force_providers (Boolean) - Run providers even if existing artist found (default: false)
  - **options - Additional options passed to ImportQuery
- Returns: ImportResult with success/failure status and detailed provider feedback
- Raises: ArgumentError if neither name nor musicbrainz_id provided, or if musicbrainz_id format invalid

## Protected Methods

### `#finder`
- Returns: DataImporters::Music::Artist::Finder instance
- Purpose: Provides artist-specific logic for finding existing records

### `#providers`
- Returns: Array of provider instances
- Current providers:
  - DataImporters::Music::Artist::Providers::MusicBrainz

### `#initialize_item(query)`
- Parameters: query (ImportQuery) - Validated artist query object
- Returns: New Music::Artist instance with name from query
- Purpose: Creates empty artist instance for population

## Usage Examples

### Import by Name
```ruby
result = DataImporters::Music::Artist::Importer.call(name: "Pink Floyd")

if result.success?
  artist = result.item
  puts "Created artist: #{artist.name} (#{artist.kind})"
  puts "Country: #{artist.country}"
  puts "MusicBrainz ID: #{artist.identifiers.find_by(identifier_type: :music_musicbrainz_artist_id)&.value}"
end
```

### Import by MusicBrainz ID
```ruby
# Direct import using MusicBrainz ID for precise matching
result = DataImporters::Music::Artist::Importer.call(
  musicbrainz_id: "83d91898-7763-47d7-b03b-b92132375c47"
)

if result.success?
  puts "Imported: #{result.item.name}"
  puts "Genres: #{result.item.categories.where(category_type: 'genre').pluck(:name).join(', ')}"
end
```

### Re-enrich Existing Artist
```ruby
# Run providers on existing artist to add new data
result = DataImporters::Music::Artist::Importer.call(
  name: "Pink Floyd",
  force_providers: true
)

if result.success?
  puts "Updated artist with fresh provider data"
  puts "Providers that ran: #{result.successful_providers.map(&:provider_name).join(', ')}"
end
```

## Import Flow

1. **Query Validation**: Creates and validates ImportQuery with provided parameters
2. **Find Existing**: Uses Finder to search by MusicBrainz ID (if provided) or name
3. **Early Return**: Returns existing artist unless force_providers is true
4. **Initialize**: Creates new Music::Artist with name if none found
5. **Provider Execution**: Runs MusicBrainz provider to populate data, saving after success
6. **Result Return**: Returns ImportResult with artist and provider feedback

## Data Populated

The MusicBrainz provider populates:
- **Basic Info**: name, kind (person/band), country
- **Dates**: year_formed, year_disbanded (bands) or born_on, year_died (persons)
- **Identifiers**: MusicBrainz artist ID, ISNI (if available)
- **Categories**: Genre and location categories from MusicBrainz tags

## Error Handling

- **Missing Parameters**: Raises ArgumentError if neither name nor musicbrainz_id provided
- **Invalid MusicBrainz ID**: Raises ArgumentError if musicbrainz_id format invalid
- **API Failures**: MusicBrainz API errors logged but don't stop import
- **Validation Failures**: Artist validation errors prevent saving
- **Duplicate Detection**: Uses MusicBrainz ID for reliable duplicate prevention

## Dependencies

- DataImporters::ImporterBase (parent class)
- DataImporters::Music::Artist::ImportQuery
- DataImporters::Music::Artist::Finder
- DataImporters::Music::Artist::Providers::MusicBrainz
- Music::Artist model
- Music::Musicbrainz::Search::ArtistSearch for API integration
- Identifier model for external ID storage
- Music::Category model for genre/location categorization