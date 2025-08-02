# DataImporters::ProviderBase

## Summary
Abstract base class for all external data providers (MusicBrainz, TMDB, etc.). Defines the interface for fetching and populating data from specific external sources.

## Public Methods

### `#populate(item, query:)`
Main method to populate item with data from external source (must be implemented by subclasses)
- Parameters:
  - item (ActiveRecord model) - The item to populate with data
  - query (ImportQuery) - Domain-specific query parameters
- Returns: ProviderResult - Success/failure status with details
- Purpose: Fetch external data and populate the provided item

## Protected Methods

### `#success_result(data_populated: [])`
Creates successful ProviderResult
- Parameters: data_populated (Array<Symbol>) - List of fields populated
- Returns: ProviderResult with success: true
- Purpose: Consistent success response format

### `#failure_result(errors:)`
Creates failed ProviderResult
- Parameters: errors (Array<String>) - List of error messages
- Returns: ProviderResult with success: false
- Purpose: Consistent failure response format

## Provider Responsibilities
Each provider should:
1. **Search external API** for relevant data
2. **Validate response** and handle API errors
3. **Map external data** to domain model attributes
4. **Create identifiers** for future duplicate detection
5. **Return detailed results** showing what was accomplished

## Data Population Strategy
Providers should:
- Only populate blank/nil fields (preserve existing data)
- Create external identifiers for reliable duplicate detection
- Handle partial data gracefully (some fields missing)
- Map external data formats to internal conventions

## Error Handling
- Network failures should return ProviderResult.failure
- Partial data should still return success if core fields populated
- Invalid responses should be logged and return failure
- Exceptions should be caught and converted to failure results

## Dependencies
- External API client libraries
- Domain-specific mapping logic
- Identifier model for creating external ID records

## Usage Pattern
This class is never used directly. Domain-specific providers implement the data fetching:

```ruby
module DataImporters
  module Music
    module Artist
      module Providers
        class MusicBrainz < DataImporters::ProviderBase
          def populate(artist, query:)
            search_result = search_for_artist(query.name)
            return failure_result(errors: search_result[:errors]) unless search_result[:success]
            
            artist_data = search_result[:data]["artists"].first
            populate_artist_data(artist, artist_data)
            create_identifiers(artist, artist_data)
            
            success_result(data_populated: [:name, :kind, :country])
          rescue => e
            failure_result(errors: ["MusicBrainz error: #{e.message}"])
          end
        end
      end
    end
  end
end
```

## Provider Result Details
ProviderResult includes:
- **Provider name**: For debugging and reporting
- **Success status**: Boolean indicating overall success
- **Data populated**: Array of field names that were populated
- **Errors**: Array of error messages for failures