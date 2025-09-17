# DataImporters::ImporterBase

## Summary
Abstract base class that orchestrates the data import process across all media types. Provides the main workflow for finding existing records, running providers, and saving results.

## Public Methods

### `.call(query:, force_providers: false)`
Main entry point for import operations
- Parameters: 
  - query (ImportQuery) - Domain-specific query object with validation
  - force_providers (Boolean) - Run providers even if existing item found (default: false)
- Returns: ImportResult - Aggregated results from all providers
- Raises: ArgumentError if query is invalid

### `#call(query:, force_providers: false)`
Instance method that performs the complete import workflow:
1. Validates the query object
2. Attempts to find existing record via finder
3. Returns early if existing item found (unless force_providers is true)
4. Initializes new item if none found
5. Runs all providers to populate data, saving after each successful provider
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

## Workflow Details

### Provider Aggregation and Saving
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

## Usage Pattern
This class is never used directly. Instead, domain-specific subclasses implement the required methods:

```ruby
module DataImporters
  module Music
    module Artist
      class Importer < DataImporters::ImporterBase
        def finder
          @finder ||= Finder.new
        end

        def providers
          @providers ||= [Providers::MusicBrainz.new]
        end

        def initialize_item(query)
          ::Music::Artist.new(name: query.name)
        end
      end
    end
  end
end
```