# DataImporters::ImporterBase

## Summary
Abstract base class that orchestrates the data import process across all media types. Supports both traditional query-based imports (search/create) and new item-based imports (enrich existing). Provides provider filtering and flexible workflow management for both manual and automated import scenarios.

## Public Methods

### `.call(query: nil, item: nil, force_providers: false, providers: nil)`
Main entry point for import operations supporting both query-based and item-based imports
- Parameters:
  - query (ImportQuery, optional) - Domain-specific query object for creating/finding records
  - item (Model, optional) - Existing record to enrich (item-based import)
  - force_providers (Boolean) - Run providers even if existing item found (default: false)
  - providers (Array, optional) - Specific provider names to run (filters available providers)
- Returns: ImportResult - Aggregated results from all providers
- Raises: ArgumentError if parameters are invalid

### `#call(query: nil, item: nil, force_providers: false, providers: nil)`
Instance method that performs the complete import workflow:
1. Validates input parameters (exactly one of query or item required)
2. For query-based imports: finds existing records or creates new ones
3. For item-based imports: uses provided item directly
4. Runs providers (all or filtered subset) to populate/enrich data
5. Saves after each successful provider
6. Returns detailed results

## Protected Methods (Must be implemented by subclasses)

### `#finder`
- Returns: Finder instance for this domain
- Purpose: Provides domain-specific logic for finding existing records

### `#providers`
- Returns: Array of provider instances
- Purpose: List of external data sources to use for this domain

### `#initialize_item(query)`
- Parameters: query (ImportQuery) - Validated query object
- Returns: New domain model instance
- Purpose: Creates empty model instance for population

## Import Modes

### Query-Based Import (Traditional)
Standard workflow for creating new records:
- Uses ImportQuery object with domain-specific validation
- Searches for existing records via finder
- Creates new items if none found
- Runs providers to populate data from external sources

### Item-Based Import (New)
Enhanced workflow for enriching existing records:
- Accepts existing model instance directly
- Skips search/creation logic entirely
- Runs providers to add/update data
- Enables re-enrichment of previously imported items

### Multi-Item Import
Special mode for importers that create multiple related items:
- Providers handle all creation logic
- Item parameter not supported (must use query)
- Used for complex imports like release collections

## Provider Management

### Provider Filtering
New `providers` parameter enables selective execution:
- Accepts array of provider names (symbols or strings)
- Converts symbols to class names (`:amazon` → "Amazon", `:music_brainz` → "MusicBrainz")
- Runs only specified providers instead of all available
- Useful for targeted re-enrichment workflows

### Provider Execution and Saving
All providers run against the same item instance, allowing multiple data sources to contribute different pieces of information. Items are saved immediately after each successful provider that makes changes, enabling:
- Background job compatibility (items are persisted before async providers run)
- Incremental updates from multiple providers
- Fast failure recovery (first provider saves basic item, later providers enhance it)

### Force Providers Option
When `force_providers: true` is passed:
- Existing items found by finder are still processed by providers
- Useful for re-enriching existing items with new provider data
- Enables adding new providers to previously imported items

### Error Handling
- Individual provider failures don't stop the import
- Items are saved after each successful provider if valid and changed
- Database save failures are logged and gracefully handled
- Failed saves convert provider success to failure result

### Result Tracking
Returns comprehensive ImportResult showing:
- Overall success/failure status
- Which providers succeeded/failed
- All data fields populated
- Complete error list
- Item persistence status (items are saved incrementally during import)

## Dependencies
- Domain-specific Finder classes
- Domain-specific Provider classes
- ImportResult and ProviderResult classes
- Rails logger for error reporting

## Usage Examples

### Query-Based Import (Create New)
```ruby
DataImporters::Music::Album::Importer.call(
  artist: artist_instance,
  title: "Album Title"
)
```

### Item-Based Import (Enrich Existing)
```ruby
DataImporters::Music::Album::Importer.call(
  item: existing_album
)
```

### Selective Provider Execution
```ruby
DataImporters::Music::Album::Importer.call(
  item: existing_album,
  providers: [:amazon, :music_brainz]
)
```

### Force Provider Execution
```ruby
DataImporters::Music::Album::Importer.call(
  artist: artist_instance,
  title: "Album Title",
  force_providers: true
)
```

## Subclass Implementation Pattern
This class is never used directly. Domain-specific subclasses implement the required methods:

```ruby
module DataImporters
  module Music
    module Album
      class Importer < DataImporters::ImporterBase
        def self.call(artist: nil, item: nil, force_providers: false, providers: nil, **options)
          if item.present?
            # Item-based import: use existing album
            super(item: item, force_providers: force_providers, providers: providers)
          else
            # Query-based import: create query object
            query = ImportQuery.new(artist: artist, **options)
            super(query: query, force_providers: force_providers, providers: providers)
          end
        end

        def finder
          @finder ||= Finder.new
        end

        def providers
          @providers ||= [
            Providers::MusicBrainz.new,
            Providers::Amazon.new
          ]
        end

        def initialize_item(query)
          ::Music::Album.new(title: query.title)
        end
      end
    end
  end
end
```