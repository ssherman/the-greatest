# 030 - MusicBrainz Series Search API Wrapper Implementation

## Status
- **Status**: Completed
- **Priority**: Medium
- **Created**: 2025-09-01
- **Started**: 2025-09-01
- **Completed**: 2025-09-01
- **Developer**: AI Assistant

## Overview
Implement a comprehensive wrapper around the MusicBrainz Series API to search for and retrieve series data, particularly "Release group series" lists like "Vice's top 100 albums of all time". This will enable importing ranked music lists with their associated release groups and rankings.

## Context
- MusicBrainz Series API provides access to curated lists like "best of" rankings
- Series can contain release groups with ordering/ranking information
- This is crucial for importing authoritative music lists to populate our ranking system
- Two API operations needed: search for series, then browse series details with release group relationships
- Following established MusicBrainz API wrapper patterns from existing search classes
- Supports our list aggregation and ranking features

## Requirements
- [x] SeriesSearch class following BaseSearch pattern
- [x] Search by series name (series field)
- [x] Search by series alias 
- [x] Search by series type (focus on "Release group series")
- [x] Search by series MBID (sid field)
- [x] Search by series tag
- [x] Search by disambiguation comment
- [x] Browse API method to get series with release group relationships
- [x] Support for inc=release-group-rels parameter
- [x] Comprehensive test coverage with mock responses
- [x] Consistent error handling and response format
- [x] Documentation for all public methods

## Technical Approach

### Architecture
Following the established pattern from existing search classes:
```
web-app/app/lib/music/musicbrainz/search/
└── series_search.rb          # Series search implementation
```

### Series Search Class Design
- Inherit from `BaseSearch` for consistent interface
- Entity type: "series"
- MBID field: "sid" (series ID)
- Available search fields from MusicBrainz API documentation

### Key Methods to Implement
1. **Search Methods**:
   - `search_by_name(name, options = {})` - Search by series name
   - `search_by_alias(alias_name, options = {})` - Search by alias
   - `search_by_type(type, options = {})` - Search by series type
   - `search_by_tag(tag, options = {})` - Search by tag
   - `search_by_comment(comment, options = {})` - Search by disambiguation

2. **Browse Method**:
   - `browse_series_with_release_groups(series_mbid, options = {})` - Get series with release group relationships
   - Uses browse API: `/ws/2/series/{mbid}?inc=release-group-rels`
   - Returns release groups with ordering information

### Response Structure
Consistent with existing search classes:
```ruby
{
  success: true/false,
  data: {
    count: 25,
    offset: 0,
    results: [...],  # Series search results or browse data
    created: "2025-09-01T..."
  },
  errors: [],
  metadata: {
    query: "...",
    endpoint: "...",
    response_time: 0.123
  }
}
```

## Dependencies
- Existing MusicBrainz API infrastructure (BaseClient, BaseSearch, exceptions)
- Faraday HTTP client (already configured)
- Minitest testing framework
- Music models (for potential future integration)

## Acceptance Criteria
- [x] Can search for series by name with results
- [x] Can search for series by type, specifically "Release group series"
- [x] Can search for series by alias and other fields
- [x] Can browse series details with release group relationships
- [x] Release group relationships include ordering/ranking information
- [x] All searches support pagination (limit/offset)
- [x] Comprehensive error handling for API failures
- [x] All methods are fully tested with mock responses
- [x] Documentation covers all public methods and usage examples
- [x] Follows established patterns from existing search classes

## Design Decisions

### API Endpoints
- **Search**: `/ws/2/series/?query=...` for finding series
- **Browse**: `/ws/2/series/{mbid}?inc=release-group-rels` for detailed relationships

### Search Fields (from MusicBrainz documentation)
- `series` - series name (diacritics ignored)
- `seriesaccent` - series name (with diacritics)  
- `alias` - any alias attached to the series
- `comment` - disambiguation comment
- `sid` - series MBID
- `tag` - tags attached to the series
- `type` - series type

### Focus on Release Group Series
- Primary use case is "Release group series" type
- These contain ranked lists of albums/release groups
- Each relationship includes ordering information (rank/position)

### Browse API for Relationships
- Search API finds series, browse API gets detailed relationships
- Similar pattern to `search_by_release_group_mbid_with_recordings` in ReleaseSearch
- inc=release-group-rels parameter includes release group relationships with ordering

### Error Handling
- Follow existing pattern with structured error responses
- Handle network errors, invalid queries, and API failures gracefully
- Comprehensive logging for debugging

## Implementation Plan

### Phase 1: Core Infrastructure
1. Create SeriesSearch class inheriting from BaseSearch
2. Implement entity_type, mbid_field, and available_fields methods
3. Add basic search_by_name method
4. Create comprehensive test structure

### Phase 2: Search Methods
1. Implement all search_by_* methods for different fields
2. Add search_by_type with focus on "Release group series"
3. Support complex queries and multiple criteria
4. Add pagination support

### Phase 3: Browse API Integration
1. Implement browse_series_with_release_groups method
2. Handle inc=release-group-rels parameter
3. Parse relationship data with ordering information
4. Test with real series data

### Phase 4: Testing and Documentation
1. Comprehensive test coverage with mock responses
2. Test all search methods and error scenarios
3. Test browse functionality with relationship data
4. Complete documentation with usage examples

## API Usage Examples

### Search for Series
```ruby
series_search = Music::Musicbrainz::Search::SeriesSearch.new(client)

# Find "best of" lists
results = series_search.search_by_name("100 Best Albums")

# Find by type
results = series_search.search_by_type("Release group series")

# Complex search
results = series_search.search_with_criteria({
  series: "Vice",
  type: "Release group series"
})
```

### Browse Series with Release Groups
```ruby
# Get series details with release group relationships
series_mbid = "28cbc99a-875f-4139-b8b0-f1dd520ec62c"
details = series_search.browse_series_with_release_groups(series_mbid)

# Response includes release groups with ordering:
# {
#   success: true,
#   data: {
#     series: {...},
#     relations: [
#       {
#         type: "part of",
#         target: "release-group-mbid",
#         ordering_key: 42,
#         release_group: {...}
#       }
#     ]
#   }
# }
```

## Future Considerations
- Caching for frequently requested series data
- Integration with list import workflows
- Support for other series types beyond release groups
- Batch operations for multiple series
- Real-time updates when series are modified

---

## Implementation Notes

### Approach Taken
Successfully implemented SeriesSearch class following the established BaseSearch pattern from existing MusicBrainz search classes (ArtistSearch, ReleaseSearch). The implementation provides both search and browse functionality for MusicBrainz Series API.

### Key Files Changed
- **Created**: `app/lib/music/musicbrainz/search/series_search.rb` - Main implementation
- **Created**: `test/lib/music/musicbrainz/search/series_search_test.rb` - Comprehensive test suite

### Challenges Encountered
1. **Browse API Response Format**: The browse API returns a single series object, not a list like search API. Implemented `process_browse_response` method to transform the response to match search API format for consistency.

2. **String vs Symbol Keys**: Had to ensure consistent use of string keys in response processing to match existing patterns and mock data structure.

3. **Error Handling**: Browse API needed custom error handling instead of using inherited helper methods due to different parameter structure.

### Deviations from Plan
- Implemented custom error handling for browse operations instead of using inherited `handle_browse_error` method
- Added `search_by_name_with_diacritics` method for better MusicBrainz API coverage
- Added convenience method `search_release_group_series` for the most common use case

### Code Examples
```ruby
# Search for series
series_search = Music::Musicbrainz::Search::SeriesSearch.new(client)
results = series_search.search_by_name("Vice's 100 Greatest Albums")
results = series_search.search_release_group_series("Rolling Stone")

# Browse with relationships
details = series_search.browse_series_with_release_groups("28cbc99a-875f-4139-b8b0-f1dd520ec62c")
# Returns release groups with ordering-key for rankings
```

### Testing Approach
- 26 comprehensive tests covering all functionality
- Mock client expectations matching actual MusicBrainz API calls
- Realistic mock responses with series data, release group relationships, and ordering keys
- Error handling tests for network failures and validation errors
- All tests pass successfully

### Performance Considerations
- Leverages existing BaseSearch infrastructure for caching and rate limiting
- Browse API calls include `inc=release-group-rels` parameter to get relationship data in single request
- Pagination support for large result sets

### Future Improvements
- Caching layer for frequently accessed series data
- Batch operations for multiple series lookups
- Integration with list import workflows
- Support for other series types beyond release groups

### Lessons Learned
- Importance of consistent response format between search and browse APIs
- String key consistency crucial for mock testing
- Custom error handling sometimes needed when inheriting from base classes

### Related PRs
*To be created when implementation is committed*

### Documentation Updated
- [x] Class documentation with comprehensive method documentation
- [x] API documentation for all public methods with parameter descriptions
- [x] Usage examples and best practices in method comments
- [x] Error handling documentation in method signatures