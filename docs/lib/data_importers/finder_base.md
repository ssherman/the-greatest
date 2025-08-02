# DataImporters::FinderBase

## Summary
Abstract base class for finding existing records before import. Provides common functionality for identifier-based lookup with domain-specific search logic.

## Public Methods

### `#call(query:)`
Main method to find existing records (must be implemented by subclasses)
- Parameters: query (ImportQuery) - Domain-specific query object
- Returns: Existing model instance or nil if not found
- Purpose: Domain-specific logic for finding existing records

## Protected Methods

### `#find_by_identifier(identifier_type:, identifier_value:, model_class:)`
Finds existing record by external identifier
- Parameters:
  - identifier_type (Symbol) - Type from Identifier enum (e.g., :music_musicbrainz_artist_id)
  - identifier_value (String) - The identifier value to search for
  - model_class (Class) - Domain model class to search within
- Returns: Model instance or nil if not found
- Purpose: Reliable duplicate detection using external identifiers

## Search Strategy
Subclasses typically implement a multi-step search strategy:
1. **External ID lookup**: Use `find_by_identifier` for most reliable matching
2. **Name matching**: Exact string comparison as fallback
3. **AI-assisted matching**: Future enhancement for fuzzy matching

## Dependencies
- Identifier model for external identifier storage
- Domain-specific models for exact matching
- External APIs for identifier discovery

## Usage Pattern
This class is never used directly. Domain-specific subclasses implement the search logic:

```ruby
module DataImporters
  module Music
    module Artist
      class Finder < DataImporters::FinderBase
        def call(query:)
          # Try MusicBrainz ID first
          search_result = search_musicbrainz(query.name)
          if search_result[:success] && search_result[:data]["artists"].any?
            mbid = search_result[:data]["artists"].first["id"]
            existing = find_by_musicbrainz_id(mbid)
            return existing if existing
          end

          # Fallback to exact name match
          find_by_name(query.name)
        end
      end
    end
  end
end
```

## Error Handling
- External API failures should not prevent fallback search methods
- Network errors should be logged but not raise exceptions
- Returns nil for any failure to find existing record