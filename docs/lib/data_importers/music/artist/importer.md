# DataImporters::Music::Artist::Importer

## Summary
Main importer for Music::Artist records. Orchestrates finding existing artists and importing from external providers, specifically designed for music artist data import from sources like MusicBrainz.

## Public Methods

### `.call(name:, **options)`
Class method entry point for artist import
- Parameters:
  - name (String) - Artist name to import (required)
  - options (Hash) - Additional import options (optional)
- Returns: ImportResult or existing artist if found
- Purpose: Convenient API for importing artists by name

Example:
```ruby
result = DataImporters::Music::Artist::Importer.call(name: "Pink Floyd")
result = DataImporters::Music::Artist::Importer.call(name: "David Bowie", country: "GB")
```

## Protected Methods

### `#finder`
- Returns: DataImporters::Music::Artist::Finder instance
- Purpose: Provides artist-specific finding logic with MusicBrainz ID and name matching

### `#providers`
- Returns: Array of provider instances
- Current providers:
  - `Providers::MusicBrainz` - Fetches data from MusicBrainz API
- Purpose: List of external data sources for artist information

### `#initialize_item(query)`
- Parameters: query (ImportQuery) - Validated artist import query
- Returns: New Music::Artist instance with name pre-populated
- Purpose: Creates empty artist model ready for data population

## Import Workflow

### 1. Query Creation
Creates ImportQuery with name validation and optional parameters.

### 2. Existing Artist Search
Uses Finder to check for existing artists via:
- MusicBrainz ID lookup (most reliable)
- Exact name matching (fallback)
- Future: AI-assisted fuzzy matching

### 3. Data Population
Runs all configured providers to populate artist data:
- Basic information (name, kind, country)
- Temporal data (formation/birth dates, disbandment/death dates)
- External identifiers (MusicBrainz ID, ISNI)

### 4. Validation & Save
Validates populated artist model and saves if valid and any provider succeeded.

## Provider Configuration
Currently configured with MusicBrainz provider. Future providers can be added:
```ruby
def providers
  @providers ||= [
    Providers::MusicBrainz.new,
    # Future providers:
    # Providers::Discogs.new,
    # Providers::AllMusic.new,
    # Providers::Wikipedia.new
  ]
end
```

## Return Values

### Existing Artist Found
Returns the existing Music::Artist instance directly (not wrapped in ImportResult).

### New Artist Import
Returns ImportResult with:
- `item` - The created Music::Artist instance
- `success?` - True if artist was successfully created and saved
- `provider_results` - Array showing what each provider accomplished
- `all_errors` - Any errors encountered during import

## Error Handling
- Network failures from external APIs are graceful (logged but don't prevent import)
- Validation failures prevent saving but provide clear error messages
- Individual provider failures don't stop other providers from running

## Dependencies
- DataImporters::Music::Artist::Finder for duplicate detection
- DataImporters::Music::Artist::Providers::MusicBrainz for data fetching
- DataImporters::Music::Artist::ImportQuery for input validation
- Music::Artist model for persistence

## Usage Examples

### Basic Import
```ruby
result = DataImporters::Music::Artist::Importer.call(name: "Pink Floyd")
if result.success?
  puts "Created #{result.item.name} (#{result.item.kind})"
else
  puts "Failed: #{result.all_errors.join(', ')}"
end
```

### Existing Artist
```ruby
existing = DataImporters::Music::Artist::Importer.call(name: "Pink Floyd")
# Returns existing Music::Artist instance if already in database
```