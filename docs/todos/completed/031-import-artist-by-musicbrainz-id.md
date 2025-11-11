# 031 - Import Artist by MusicBrainz ID Enhancement

## Status
- **Status**: Completed
- **Priority**: Medium
- **Created**: 2025-09-02
- **Started**: 2025-09-02
- **Completed**: 2025-09-03
- **Developer**: AI Assistant

## Overview
Enhance the existing artist importer to support importing artists by MusicBrainz ID in addition to the current name-based import. This will enable more precise artist identification and import using authoritative MusicBrainz identifiers.

## Context
- **Why is this needed?**
  - Current artist import only supports searching by name, which can be ambiguous
  - MusicBrainz IDs provide precise, unambiguous artist identification
  - Enables importing artists from series/rankings where we already have MusicBrainz IDs
  - Supports the new SeriesSearch functionality which returns release groups with artist MBIDs

- **What problem does it solve?**
  - Eliminates ambiguity when multiple artists share the same name
  - Enables direct import from MusicBrainz series data (e.g., "Vice's 100 Greatest Albums")
  - Provides more reliable duplicate detection using MusicBrainz identifiers
  - Allows for higher quality data import with verified artist entities

- **How does it fit into the larger system?**
  - Extends existing `DataImporters::Music::Artist::Importer` system
  - Integrates with new `Music::Musicbrainz::Search::SeriesSearch` for list imports
  - Uses existing MusicBrainz API wrapper and identifier system
  - Maintains compatibility with current name-based import workflow

## Requirements
- [x] Update `DataImporters::Music::Artist::ImportQuery` to accept optional `musicbrainz_id` parameter
- [x] Modify validation to require either `name` OR `musicbrainz_id` (not both required)
- [x] Enhance `DataImporters::Music::Artist::Finder` to search by MusicBrainz ID using identifiers relationship
- [x] Add new lookup method to `Music::Musicbrainz::Search::ArtistSearch` for direct MBID lookup
- [x] Update `DataImporters::Music::Artist::Providers::MusicBrainz` to handle direct lookups
- [x] Ensure all existing tests continue to pass
- [x] Add comprehensive tests for new MusicBrainz ID import functionality
- [x] Update documentation for new import capabilities

## Technical Approach

### Query Object Enhancement
```ruby
# Current usage
DataImporters::Music::Artist::Importer.call(name: "Pink Floyd")

# New usage options
DataImporters::Music::Artist::Importer.call(musicbrainz_id: "8538e728-ca0b-4321-b7e5-cff6565dd4c0")
DataImporters::Music::Artist::Importer.call(name: "Pink Floyd") # Still supported
```

### Validation Logic Update
```ruby
# Either name OR musicbrainz_id required, but not both mandatory
validates :name, presence: true, unless: :musicbrainz_id?
validates :musicbrainz_id, presence: true, unless: :name?
validates :musicbrainz_id, format: { with: UUID_REGEX }, if: :musicbrainz_id?
```

### Finder Enhancement
```ruby
def find_existing_item
  return find_by_musicbrainz_id if query.musicbrainz_id.present?
  find_by_name # Existing logic
end

private

def find_by_musicbrainz_id
  Music::Artist.joins(:identifiers)
                .where(identifiers: { 
                  identifier_type: 'musicbrainz_id', 
                  value: query.musicbrainz_id 
                })
                .first
end
```

### New ArtistSearch Method
```ruby
# Add to Music::Musicbrainz::Search::ArtistSearch
def lookup_by_mbid(mbid, options = {})
  # Use MusicBrainz lookup API: /ws/2/artist/{mbid}?inc=genres
  # Returns single artist with full data including genres
end
```

### Provider Enhancement
```ruby
def populate_item
  if query.musicbrainz_id.present?
    lookup_by_mbid_and_populate
  else
    search_by_name_and_populate # Existing logic
  end
end
```

### MusicBrainz Lookup API
- **Endpoint**: `/ws/2/artist/{mbid}?fmt=json&inc=genres`
- **Returns**: Single artist object with complete data including genres
- **Faster**: Direct lookup is more efficient than search + filtering

## Dependencies
- Existing `DataImporters::Music::Artist::*` classes (will be enhanced)
- Existing `Music::Musicbrainz::Search::ArtistSearch` (will add lookup method)
- Existing identifiers system for duplicate detection
- UUID validation for MusicBrainz ID format
- All existing Music::Artist model validations and associations

## Acceptance Criteria
- [x] Can import artist by MusicBrainz ID: `Importer.call(musicbrainz_id: "8538e728-ca0b-4321-b7e5-cff6565dd4c0")`
- [x] Can still import artist by name: `Importer.call(name: "Depeche Mode")` 
- [x] Validation requires either name OR musicbrainz_id (but not both required)
- [x] MusicBrainz ID must be valid UUID format when provided
- [x] Finder correctly identifies existing artists by MusicBrainz ID via identifiers
- [x] New lookup API method retrieves complete artist data from MusicBrainz
- [x] Import includes genre data from MusicBrainz lookup API (from both "tags" and "genres" fields)
- [x] All existing name-based import functionality remains unchanged
- [x] Comprehensive test coverage for new MusicBrainz ID import paths
- [x] Updated documentation reflects new import capabilities

## Design Decisions

### API Design Choice
- **Lookup vs Search**: Use direct lookup API (`/ws/2/artist/{mbid}`) for MusicBrainz IDs instead of search API
- **Benefits**: More efficient, returns complete data, includes genres
- **Implementation**: Add `lookup_by_mbid` method to ArtistSearch class

### Validation Strategy
- **Either/Or Validation**: Require either name OR musicbrainz_id, not both mandatory
- **UUID Validation**: Validate MusicBrainz ID format when provided
- **Backwards Compatibility**: Existing name-only imports continue to work unchanged

### Finder Enhancement
- **Identifier-Based Lookup**: Use existing identifiers relationship for duplicate detection
- **Fallback Logic**: If MusicBrainz ID provided, use it first; otherwise fall back to name matching
- **Performance**: Index on identifiers table for efficient lookups

### Provider Logic
- **Conditional Population**: Different data retrieval path based on query type
- **Data Richness**: Lookup API provides richer data (including genres) than search API
- **Error Handling**: Graceful handling of invalid MusicBrainz IDs or network failures

## Implementation Plan

### Phase 1: Core Infrastructure Updates
1. Update `ImportQuery` to accept and validate `musicbrainz_id` parameter
2. Modify validation logic to require either name OR musicbrainz_id
3. Add UUID format validation for MusicBrainz IDs

### Phase 2: Finder Enhancement
1. Add `find_by_musicbrainz_id` method using identifiers relationship
2. Update main finder logic to use MusicBrainz ID when available
3. Ensure fallback to name-based search works correctly

### Phase 3: MusicBrainz API Enhancement
1. Add `lookup_by_mbid` method to `ArtistSearch` class
2. Implement direct MusicBrainz lookup API call with genres inclusion
3. Add proper error handling for lookup failures

### Phase 4: Provider Integration
1. Update `MusicBrainz` provider to handle lookup vs search scenarios
2. Ensure genre data is properly imported from lookup API
3. Maintain existing search-based population for name imports

### Phase 5: Testing and Documentation
1. Add comprehensive tests for MusicBrainz ID import scenarios
2. Test edge cases (invalid IDs, network failures, etc.)
3. Verify all existing tests continue to pass
4. Update class documentation and usage examples

---

## Implementation Notes

### Approach Taken
The implementation followed the planned 5-phase approach with successful completion of all phases. The either/or validation pattern was implemented using Rails validation conditionals, and the MusicBrainz ID prioritization was handled through conditional logic in both the finder and provider layers.

### Key Files Changed
- `app/lib/data_importers/music/artist/import_query.rb` - Added musicbrainz_id parameter and either/or validation
- `app/lib/data_importers/music/artist/finder.rb` - Enhanced to prioritize MusicBrainz ID lookups over name searches  
- `app/lib/music/musicbrainz/search/artist_search.rb` - Added lookup_by_mbid method for direct API calls
- `app/lib/data_importers/music/artist/providers/music_brainz.rb` - Updated for conditional lookup vs search API usage
- `app/lib/data_importers/music/artist/importer.rb` - Updated method signature to accept both parameters
- `test/lib/data_importers/music/artist/import_query_test.rb` - Added validation tests for new functionality
- `test/lib/data_importers/music/artist/finder_test.rb` - Added MusicBrainz ID lookup tests
- `test/lib/music/musicbrainz/search/artist_search_test.rb` - Added lookup method tests
- `test/lib/data_importers/music/artist/providers/music_brainz_test.rb` - Added provider lookup tests
- `test/lib/data_importers/music/artist/importer_test.rb` - Added comprehensive integration tests
- `test/lib/music/musicbrainz/search/series_search_test.rb` - Fixed test expectation after error handling update

### Challenges Encountered
1. **Genre Processing Issue**: Initially only extracted from "tags" field, but user identified that genres also come from separate "genres" field. Fixed by creating `extract_category_names_from_field` method to handle both.
2. **Method Signature Error**: ArgumentError about missing :name keyword when calling Importer.call. Fixed by updating method signature to accept both name and musicbrainz_id as optional parameters.
3. **Test Failures**: Three test failures occurred after implementation:
   - Two ImportQuery tests expecting new hash format - fixed by updating test expectations
   - One SeriesSearch test expecting different error structure - fixed by updating error handling expectations
4. **Name Override Issue**: Final test failure where MusicBrainz name wasn't being used when both name and musicbrainz_id were provided. Fixed by ensuring MusicBrainz data is always used as authoritative source.

### Deviations from Plan
- **Error Handling**: Used inherited error handling methods from base classes rather than custom implementation
- **Genre Processing**: Enhanced beyond plan to extract from both "tags" and "genres" fields for comprehensive category creation
- **API Pattern**: Confirmed direct lookup API was correct approach rather than using browse_by_params pattern

### Code Examples

**Import by MusicBrainz ID**:
```ruby
result = DataImporters::Music::Artist::Importer.call(
  musicbrainz_id: "8538e728-ca0b-4321-b7e5-cff6565dd4c0"
)
```

**Either/Or Validation**:
```ruby
validates :name, presence: true, unless: :musicbrainz_id?
validates :musicbrainz_id, presence: true, unless: :name?
validates :musicbrainz_id, format: { with: UUID_REGEX }, if: :musicbrainz_id?
```

**Finder Priority Logic**:
```ruby
def call(query:)
  return find_existing_item(query) if query.musicbrainz_id.present?
  find_existing_item_by_name(query)
end
```

**Provider Conditional API Usage**:
```ruby
api_result = if query.musicbrainz_id.present?
  lookup_artist_by_mbid(query.musicbrainz_id)
else
  search_for_artist(query.name)
end
```

### Testing Approach
Comprehensive testing was implemented following the established testing patterns:
- **Unit Tests**: Each component (ImportQuery, Finder, ArtistSearch, Provider) tested independently
- **Integration Tests**: Full import flow tested through Importer with various scenarios
- **Edge Cases**: Invalid UUIDs, missing parameters, API failures, existing artists
- **Mocking**: External MusicBrainz API calls mocked using Mocha for reliable testing
- **Fixtures**: Used existing artist fixtures for existing artist detection scenarios

**Test Coverage Added**:
- 35+ new test cases across 5 test files
- All new functionality paths covered
- Edge case handling verified
- Backward compatibility confirmed

### Performance Considerations
- **Direct Lookup API**: Using `/artist/{mbid}` endpoint is more efficient than search+filter approach
- **Prioritized Lookups**: MusicBrainz ID lookups bypass name-based search when available
- **Enhanced Data**: Lookup API returns richer data including genres, reducing additional API calls

### Future Improvements
- **Bulk Import**: Could add batch processing for multiple MusicBrainz IDs
- **Caching**: Consider caching MusicBrainz lookup results for repeated imports
- **Provider Expansion**: Additional providers could leverage the MusicBrainz ID for cross-referencing
- **Validation**: Could add existence validation for MusicBrainz IDs against MusicBrainz API

### Lessons Learned
- **Genre Data Sources**: MusicBrainz provides genre data in multiple fields ("tags" and "genres") - both should be processed
- **Authoritative Data**: Always use MusicBrainz data as authoritative source, don't preserve existing names
- **Test Maintenance**: When adding new functionality, existing tests may need updates for new data structures
- **API Patterns**: Direct lookup APIs provide better performance and data richness than search APIs when identifiers are available

### Related PRs
*Implementation was done directly - no PRs created*

### Documentation Updated
- [x] ImportQuery class documentation updated with new parameter
- [x] Finder class documentation updated with MusicBrainz ID priority logic
- [x] ArtistSearch class documentation updated with lookup method
- [x] Provider class documentation updated with conditional API usage
- [x] Usage examples updated with MusicBrainz ID import scenarios