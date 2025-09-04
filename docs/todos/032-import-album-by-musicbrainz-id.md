# 032 - Import Album by MusicBrainz Release Group ID Enhancement

## Status
- **Status**: Completed
- **Priority**: Medium
- **Created**: 2025-09-03
- **Started**: 2025-09-04
- **Completed**: 2025-09-04
- **Developer**: AI Assistant

## Overview
Enhance the existing album importer to support importing albums by MusicBrainz Release Group ID in addition to the current artist-and-name based import. This will enable precise album identification and import using authoritative MusicBrainz identifiers, including automatic artist import and association.

## Context
- **Why is this needed?**
  - Current album import requires two parameters (artist instance + album name), which can be cumbersome
  - MusicBrainz Release Group IDs provide precise, unambiguous album identification
  - Enables importing albums from series/rankings where we already have MusicBrainz Release Group IDs
  - Supports streamlined import workflow using only a single identifier
  - Allows for importing albums with multiple artists automatically

- **What problem does it solve?**
  - Eliminates need to pre-fetch artist instances before album import
  - Handles complex artist relationships (collaborations, features, etc.) automatically
  - Provides more reliable duplicate detection using MusicBrainz identifiers
  - Enables direct import from MusicBrainz series data and external sources
  - Reduces import complexity from two-step to single-step process

- **How does it fit into the larger system?**
  - Extends existing `DataImporters::Music::Album::Importer` system
  - Integrates with existing artist import system for automatic artist handling
  - Uses existing MusicBrainz API wrapper and identifier system
  - Maintains compatibility with current artist+name import workflow
  - Leverages recent MusicBrainz ID artist import functionality (todo 031)

## Requirements
- [x] Add `lookup_by_release_group_mbid` method to `Music::Musicbrainz::Search::ReleaseGroupSearch`
- [x] Update `DataImporters::Music::Album::ImportQuery` to accept optional `release_group_musicbrainz_id` parameter
- [x] Modify validation to require either `(artist + name)` OR `release_group_musicbrainz_id`
- [x] Update `DataImporters::Music::Album::Providers::MusicBrainz` to handle direct release group lookups
- [x] Implement automatic artist import/association from release group artist-credit data
- [x] Add genre and tag processing from MusicBrainz release group data
- [x] Ensure all existing tests continue to pass
- [x] Add comprehensive tests for new MusicBrainz Release Group ID import functionality
- [x] Update documentation for new import capabilities

## Technical Approach

### Query Object Enhancement
```ruby
# Current usage
DataImporters::Music::Album::Importer.call(artist: artist_instance, name: "Piñata")

# New usage options
DataImporters::Music::Album::Importer.call(release_group_musicbrainz_id: "6b9a9e04-abd7-4666-86ba-bb220ef4c3b2")
DataImporters::Music::Album::Importer.call(artist: artist_instance, name: "Piñata") # Still supported
```

### Validation Logic Update
```ruby
# Either (artist + name) OR release_group_musicbrainz_id required
validates :artist, presence: true, unless: :release_group_musicbrainz_id?
validates :name, presence: true, unless: :release_group_musicbrainz_id?
validates :release_group_musicbrainz_id, presence: true, unless: :artist_and_name?
validates :release_group_musicbrainz_id, format: { with: UUID_REGEX }, if: :release_group_musicbrainz_id?

private

def artist_and_name?
  artist.present? && name.present?
end
```

### ReleaseGroupSearch Enhancement
```ruby
# Add to Music::Musicbrainz::Search::ReleaseGroupSearch
def lookup_by_release_group_mbid(mbid, options = {})
  # Use MusicBrainz lookup API: /ws/2/release-group/{mbid}?inc=artist-credits+genres
  # Returns single release group with full data including artist credits and genres
end
```

### Provider Enhancement
```ruby
def populate_item
  if query.release_group_musicbrainz_id.present?
    lookup_by_release_group_and_populate
  else
    search_by_artist_and_name_and_populate # Existing logic
  end
end

private

def lookup_by_release_group_and_populate
  # 1. Lookup release group data from MusicBrainz
  # 2. Import/find artists from artist-credit data
  # 3. Create album with artist associations
  # 4. Process genres and tags
end
```

### Automatic Artist Handling
```ruby
# Process artist-credit array from MusicBrainz response
def process_artist_credits(artist_credits)
  artist_credits.map do |credit|
    artist_mbid = credit.dig("artist", "id")
    # Use existing artist importer with MusicBrainz ID
    result = DataImporters::Music::Artist::Importer.call(musicbrainz_id: artist_mbid)
    result.item if result.success?
  end.compact
end
```

### MusicBrainz Release Group Lookup API
- **Endpoint**: `/ws/2/release-group/{mbid}?fmt=json&inc=artist-credits+genres`
- **Returns**: Single release group object with complete data including artist credits and genres
- **Artist Credits**: Array of artist objects with full artist data including their own MusicBrainz IDs
- **Genres**: Both "genres" and "tags" fields for comprehensive categorization

## Dependencies
- Recent MusicBrainz ID artist import functionality (todo 031) - REQUIRED
- Existing `DataImporters::Music::Album::*` classes (will be enhanced)
- Existing `Music::Musicbrainz::Search::ReleaseGroupSearch` (will add lookup method)
- Existing identifiers system for duplicate detection
- UUID validation for MusicBrainz Release Group ID format
- All existing Music::Album model validations and associations

## Acceptance Criteria
- [x] Can import album by Release Group ID: `Importer.call(release_group_musicbrainz_id: "6b9a9e04-abd7-4666-86ba-bb220ef4c3b2")`
- [x] Can still import album by artist+name: `Importer.call(artist: artist_instance, name: "Album Name")`
- [x] Validation requires either (artist + name) OR release_group_musicbrainz_id
- [x] MusicBrainz Release Group ID must be valid UUID format when provided
- [x] Artists are automatically imported/found using their MusicBrainz IDs from artist-credit data
- [x] Multiple artists are properly associated with the album (collaborations, features, etc.)
- [x] New lookup API method retrieves complete release group data from MusicBrainz
- [x] Import includes genre data from MusicBrainz release group lookup API
- [x] All existing artist+name import functionality remains unchanged
- [x] Comprehensive test coverage for new MusicBrainz Release Group ID import paths
- [x] Updated documentation reflects new import capabilities

## Design Decisions

### API Design Choice
- **Lookup vs Search**: Use direct lookup API (`/ws/2/release-group/{mbid}`) for MusicBrainz Release Group IDs instead of search API
- **Benefits**: More efficient, returns complete data, includes artist credits and genres
- **Implementation**: Add `lookup_by_release_group_mbid` method to ReleaseGroupSearch class

### Validation Strategy
- **Either/Or Validation**: Require either (artist + name) OR release_group_musicbrainz_id
- **UUID Validation**: Validate MusicBrainz Release Group ID format when provided
- **Backwards Compatibility**: Existing artist+name imports continue to work unchanged

### Artist Handling Strategy
- **Automatic Import**: Use existing artist importer to handle artists from artist-credit data
- **MusicBrainz ID Priority**: Import artists by their MusicBrainz IDs for consistency
- **Multiple Artists**: Support albums with multiple artists/collaborations
- **Error Handling**: Graceful handling when artist import fails

### Provider Logic
- **Conditional Population**: Different data retrieval path based on query type
- **Data Richness**: Lookup API provides richer data (including genres and full artist data) than search API
- **Artist-Credit Processing**: Extract and process all artists from MusicBrainz artist-credit array
- **Genre Processing**: Process both "tags" and "genres" fields like in artist import (todo 031)

## Implementation Plan

### Phase 1: Core Infrastructure Updates
1. Update `ImportQuery` to accept and validate `release_group_musicbrainz_id` parameter
2. Modify validation logic to require either (artist + name) OR release_group_musicbrainz_id
3. Add UUID format validation for MusicBrainz Release Group IDs

### Phase 2: MusicBrainz API Enhancement
1. Add `lookup_by_release_group_mbid` method to `ReleaseGroupSearch` class
2. Implement direct MusicBrainz lookup API call with artist-credits and genres inclusion
3. Add proper error handling for lookup failures

### Phase 3: Provider Integration
1. Update `MusicBrainz` provider to handle lookup vs search scenarios
2. Implement artist-credit processing and automatic artist import
3. Ensure genre data is properly imported from lookup API
4. Maintain existing search-based population for artist+name imports

### Phase 4: Artist Import Integration
1. Process artist-credit array from MusicBrainz response
2. Use existing artist importer with MusicBrainz IDs for each artist
3. Handle multiple artist associations for the album
4. Add error handling for artist import failures

### Phase 5: Testing and Documentation
1. Add comprehensive tests for MusicBrainz Release Group ID import scenarios
2. Test edge cases (invalid IDs, network failures, artist import failures, etc.)
3. Test multiple artist scenarios (collaborations, features)
4. Verify all existing tests continue to pass
5. Update class documentation and usage examples

---

## Implementation Notes

### Approach Taken
Successfully implemented MusicBrainz Release Group ID album import by extending existing importer infrastructure. The implementation follows a conditional approach where the system uses either direct MusicBrainz lookup (for Release Group IDs) or existing search functionality (for artist+name pairs). Artist import integration leverages the recently completed artist import system (todo 031) for automatic artist handling.

### Key Files Changed
- `app/lib/data_importers/music/album/import_query.rb` - Added release_group_musicbrainz_id parameter with either/or validation
- `app/lib/data_importers/music/album/importer.rb` - Updated method signature to accept release_group_musicbrainz_id
- `app/lib/data_importers/music/album/finder.rb` - Enhanced with MusicBrainz ID lookup priority and find_by_musicbrainz_id_only method  
- `app/lib/data_importers/music/album/providers/music_brainz.rb` - Updated populate method for conditional lookup vs search with automatic artist import from artist-credit data
- `app/lib/music/musicbrainz/search/release_group_search.rb` - Added lookup_by_release_group_mbid method for direct MusicBrainz API calls
- `test/lib/data_importers/music/album/import_query_test.rb` - Added 15 new tests for validation logic
- `test/lib/music/musicbrainz/search/release_group_search_test.rb` - Added 6 new tests for lookup functionality
- `test/lib/data_importers/music/album/finder_test.rb` - Added 5 new tests for MusicBrainz ID finder logic
- `test/lib/data_importers/music/album/importer_test.rb` - Added 6 new tests for integration scenarios
- `test/lib/data_importers/music/album/providers/music_brainz_test.rb` - Added 5 new tests for provider lookup functionality

### Challenges Encountered
1. **Test Stub Inconsistency**: Initial test failures occurred because test stubs returned `Music::Artist` objects directly instead of `ImportResult` objects, causing provider logic to fail. The provider expects `ImportResult` objects for new artist imports or `Music::Artist` objects for existing artists found by finder.

2. **Association Persistence**: Tests that checked `album.artists` failed because associations were only built (not saved). Added `album.save!` calls in tests where associations need to be queried from the database.

3. **UUID Validation Error Handling**: Ensured that `QueryError` exceptions from UUID validation propagate correctly through the error handling chain instead of being caught by generic error handlers.

### Deviations from Plan
No major deviations from the original plan. The implementation closely followed the proposed technical approach including:
- Either/or validation strategy
- Direct lookup API usage for Release Group IDs
- Automatic artist import from artist-credit data
- Genre processing from both tags and genres fields
- Comprehensive test coverage across all components

### Code Examples
```ruby
# New MusicBrainz Release Group ID import
result = DataImporters::Music::Album::Importer.call(
  release_group_musicbrainz_id: "6b9a9e04-abd7-4666-86ba-bb220ef4c3b2"
)

# Existing artist+name import (unchanged)  
result = DataImporters::Music::Album::Importer.call(
  artist: artist_instance, 
  title: "Album Name"
)

# Either/or validation in ImportQuery
validates :artist, presence: true, unless: :release_group_musicbrainz_id?
validates :title, presence: true, unless: :release_group_musicbrainz_id?
validates :release_group_musicbrainz_id, presence: true, unless: :artist_and_title?

# Direct MusicBrainz lookup API
def lookup_by_release_group_mbid(mbid, options = {})
  validate_mbid!(mbid)
  enhanced_options = options.merge(inc: "artist-credits+genres")
  response = client.get("release-group/#{mbid}", enhanced_options)
  process_lookup_response(response)
end

# Automatic artist import from artist-credit data
def import_artists_from_artist_credits(artist_credits)
  artists = artist_credits.map do |credit|
    artist_mbid = credit.dig("artist", "id")
    result = DataImporters::Music::Artist::Importer.call(musicbrainz_id: artist_mbid)
    result.is_a?(Music::Artist) ? result : result.item if result.success?
  end.compact
end
```

### Testing Approach
Comprehensive testing with 37 new tests across all components:
- **Unit tests** for each enhanced class (ImportQuery, ReleaseGroupSearch, Finder, Provider)
- **Integration tests** for full import workflows using MusicBrainz Release Group IDs
- **Edge case testing** for invalid UUIDs, network failures, artist import failures
- **Multiple artist scenarios** for collaborations and featured artists
- **Genre processing tests** for both tags and genres fields
- **Backwards compatibility tests** ensuring existing functionality remains unchanged

All tests use proper mocking with Mocha to avoid external API calls, and include proper test data fixtures for consistent testing.

### Performance Considerations
- **Direct lookup vs search**: Using MusicBrainz lookup API (`/ws/2/release-group/{mbid}`) instead of search API provides better performance and richer data
- **Artist import optimization**: Leverages existing artist import system to avoid duplicate artist creation
- **Database efficiency**: Uses existing identifier system for duplicate album detection
- **API efficiency**: Single lookup call provides complete album and artist data including genres

### Future Improvements
- Consider implementing bulk import functionality for multiple Release Group IDs
- Add caching layer for frequently accessed MusicBrainz data
- Consider implementing artist validation/matching for improved data quality
- Add support for release (not just release group) imports for more granular album data

### Lessons Learned
- **Test mocking consistency is critical**: Ensuring test stubs return the correct object types (ImportResult vs direct models) is essential for integration tests
- **Association testing requires persistence**: When testing ActiveRecord associations through queries, the records need to be saved first
- **Either/or validation patterns work well**: The conditional validation approach provides clean separation between different import modes while maintaining backwards compatibility
- **Provider patterns scale well**: The existing provider architecture easily accommodated new lookup-based data retrieval alongside existing search-based retrieval

### Related PRs
*To be created when committing implementation*

### Documentation Updated
- [x] ImportQuery class documentation updated with release_group_musicbrainz_id parameter
- [x] ReleaseGroupSearch class documentation updated with lookup_by_release_group_mbid method
- [x] Provider class documentation updated with conditional lookup logic
- [x] All test files include comprehensive documentation of new functionality
- [x] Usage examples updated with MusicBrainz Release Group ID import patterns