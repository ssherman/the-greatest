# DataImporters::ProviderBase

## Summary
Abstract base class for all external data providers. Defines the interface for fetching and populating data from external sources like MusicBrainz, Amazon, etc.

## Public Methods

### `#populate(item, query:)` 
**Must be implemented by subclasses**
- Parameters: 
  - item (ActiveRecord model) - The item to populate with data
  - query (ImportQuery) - Domain-specific query object with search parameters
- Returns: ProviderResult - Success/failure status with provider feedback
- Purpose: Fetch data from external source and populate the item

## Protected Methods

### `#success_result(data_populated: [])`
Creates successful provider result
- Parameters:
  - data_populated (Array, optional) - List of fields/attributes populated
- Returns: ProviderResult with success: true and provider name

### `#failure_result(errors:)`
Creates failed provider result
- Parameters:
  - errors (Array) - Error messages describing what went wrong
- Returns: ProviderResult with success: false and provider name

## Usage Pattern

Subclasses implement the populate method to:
1. Fetch data from external API using query parameters
2. Populate item attributes with fetched data
3. Create identifiers using `find_or_initialize_by` to prevent duplicates
4. Return success_result() or failure_result() based on outcome

## Implementation Example

```ruby
module DataImporters
  module Music
    module Artist
      module Providers
        class MusicBrainz < DataImporters::ProviderBase
          def populate(item, query:)
            # Fetch from MusicBrainz API
            api_data = fetch_artist_data(query)
            
            # Populate item attributes
            item.assign_attributes(
              name: api_data["name"],
              country: api_data["country"]
            )
            
            # Create identifiers safely
            item.identifiers.find_or_initialize_by(
              identifier_type: :music_musicbrainz_artist_id,
              value: api_data["id"]
            )
            
            # Return success
            success_result(data_populated: %w[name country identifiers])
          rescue => e
            failure_result(errors: [e.message])
          end
        end
      end
    end
  end
end
```

## Best Practices

### Identifier Creation
Always use `find_or_initialize_by` or `find_or_create_by` to prevent duplicate identifiers:
```ruby
# ✅ Correct - prevents duplicates
item.identifiers.find_or_initialize_by(
  identifier_type: :music_musicbrainz_artist_id,
  value: external_id
)

# ❌ Wrong - creates duplicates on re-runs
item.identifiers.build(
  identifier_type: :music_musicbrainz_artist_id,
  value: external_id
)
```

### Error Handling
- Catch and handle external API errors gracefully
- Return failure_result() with descriptive error messages
- Don't raise exceptions unless critical failure

### Async Patterns (Future)
For slow APIs, providers can launch background jobs:
```ruby
def populate(item, query:)
  SlowApiEnrichmentJob.perform_async(item.id, query.to_h)
  success_result(data_populated: %w[background_job_queued])
end
```

## Dependencies
- External API clients (Music::Musicbrainz, etc.)
- ActiveRecord models for item manipulation
- Identifier model for external ID management
- ProviderResult class for standardized responses
- Background job framework (Sidekiq) for async providers