# 017 - Identifiers Model Implementation

## Status
- **Status**: Completed
- **Priority**: High
- **Created**: 2025-07-27
- **Started**: 2025-07-27
- **Completed**: 2025-07-27
- **Developer**: AI Assistant

## Overview
Implement a comprehensive identifiers model that stores external IDs for all media objects across books, music, and video games. This will enable data import, API integration, and cross-platform linking for all content in The Greatest platform.

## Context
- Each media type has multiple external identifiers from different services and databases
- We need a unified way to store and query these identifiers for data import and API integration
- Identifiers are critical for checking if items already exist during data import (MusicBrainz, Discogs, IGDB, etc.)
- Performance is crucial as identifier lookups will be frequent during data import and enrichment
- Following our AI-first development principles with clear, testable interfaces
- Focused on music domain initially, with extensible design for future media types
- External links (Spotify, YouTube, etc.) will be handled by a separate links feature

## Requirements
- [ ] Create Identifier model with polymorphic associations
- [ ] Support all major identifier types for each media domain
- [ ] Implement proper database indexes for fast lookups
- [ ] Add comprehensive validations and business rules
- [ ] Create service objects for identifier management
- [ ] Add comprehensive test coverage with fixtures
- [ ] Document all identifier types and their sources
- [ ] Implement identifier lookup and resolution methods

## Technical Approach

### Database Schema
```sql
CREATE TABLE identifiers (
  id bigint PRIMARY KEY,
  identifiable_type varchar NOT NULL,
  identifiable_id bigint NOT NULL,
  identifier_type integer NOT NULL,
  value varchar NOT NULL,
  created_at timestamp NOT NULL,
  updated_at timestamp NOT NULL,
  UNIQUE(identifiable_type, identifier_type, value, identifiable_id),
  INDEX(identifiable_type, value)
);
```

### Model Structure
- `Identifier` model with polymorphic `belongs_to :identifiable`
- Enum for `identifier_type` covering all media domains
- Service objects for identifier management and resolution

### Identifier Types by Domain

#### Books
- `books_isbn10` - International Standard Book Number (10 digits)
- `books_isbn13` - International Standard Book Number (13 digits)
- `books_asin` - Amazon Standard Identification Number
- `books_ean13` - European Article Number (13 digits)
- `books_goodreads_id` - Goodreads book ID
- `books_librarything_id` - LibraryThing work ID
- `books_openlibrary_id` - Open Library work ID
- `books_bookshop_org_id` - Bookshop.org book ID
- `books_worldcat_id` - WorldCat OCLC number
- `books_google_books_id` - Google Books volume ID

#### Music - Artists
- `music_musicbrainz_artist_id` - MusicBrainz artist MBID
- `music_isni` - International Standard Name Identifier
- `music_discogs_artist_id` - Discogs artist ID
- `music_allmusic_artist_id` - AllMusic artist ID

#### Music - Albums
- `music_musicbrainz_release_group_id` - MusicBrainz release group MBID
- `music_musicbrainz_release_id` - MusicBrainz release MBID
- `music_asin` - Amazon Standard Identification Number
- `music_discogs_release_id` - Discogs release ID
- `music_allmusic_album_id` - AllMusic album ID

#### Music - Songs
- `music_musicbrainz_recording_id` - MusicBrainz recording MBID
- `music_musicbrainz_work_id` - MusicBrainz work MBID
- `music_isrc` - International Standard Recording Code

#### Music - Releases
- `music_musicbrainz_release_id` - MusicBrainz release MBID
- `music_discogs_release_id` - Discogs release ID

#### Video Games
- `games_igdb_id` - Internet Game Database ID

## Dependencies
- Rails 8 with PostgreSQL 17
- Existing polymorphic association patterns
- Enum support for identifier types

## Acceptance Criteria
- [ ] Can store and retrieve identifiers for any media object
- [ ] Fast lookups by identifier type and value
- [ ] Proper validation of identifier formats
- [ ] Comprehensive test coverage
- [ ] Service objects for identifier management
- [ ] Documentation for all identifier types

## Design Decisions

### Polymorphic Association
- Use `identifiable` as the polymorphic association name
- Follows Rails conventions and our existing patterns
- Allows any model to have identifiers

### Identifier Type Enum
- Single enum covering all domains
- Prefixed by domain for clarity (e.g., `books_isbn13`, `music_musicbrainz_artist_id`)
- Allows for easy filtering and querying

### Simple Storage
- Focus on core identifier data only
- No additional metadata or source tracking
- Clean, minimal schema for performance

### Uniqueness Constraints
- Prevent duplicate identifiers for same object
- Allow same identifier value across different objects
- Support multiple identifiers of same type per object if needed

### Performance Considerations
- Primary unique index on `(identifiable_type, identifier_type, value, identifiable_id)` for specific lookups
- Secondary index on `(identifiable_type, value)` for value-only searches (e.g., finding books by any ISBN format)
- PostgreSQL 17 can use both indexes efficiently for different query patterns

## Implementation Plan

### Phase 1: Core Model
1. Create Identifier model and migration
2. Implement polymorphic associations
3. Add identifier type enum
4. Create basic validations and indexes
5. Write comprehensive tests

### Phase 2: Service Objects
1. Create IdentifierService for CRUD operations
2. Add IdentifierImporter for bulk operations
3. Create validation services for identifier formats

### Phase 3: Integration
1. Add identifier associations to existing models
2. Update import services to use identifiers
3. Add identifier lookup methods to models
4. Create admin interface for identifier management

### Phase 4: Documentation
1. Document all identifier types and sources
2. Create usage examples and patterns
3. Add API documentation for identifier endpoints
4. Update model documentation files

## Service Objects

### IdentifierService
```ruby
class IdentifierService
  def self.add_identifier(identifiable, type, value)
    # Add identifier to object
  end
  
  def self.find_by_identifier(type, value)
    # Find object by identifier
  end
  
  def self.resolve_identifiers(identifiable)
    # Get all identifiers for object
  end
end
```



## Testing Strategy
- Unit tests for Identifier model
- Integration tests for polymorphic associations
- Service object tests with mocked external APIs
- Performance tests for identifier lookups
- Fixtures with realistic identifier data

## Future Enhancements
- Movie identifier types (IMDB, TMDB, etc.)
- Additional video game identifiers (Steam, PlayStation, Xbox, etc.)
- Wikipedia page IDs (as part of separate links feature)
- Spotify, Apple Music, YouTube IDs (as part of separate links feature)
- Identifier confidence scoring
- Automatic identifier validation

---

## Implementation Notes

### Approach Taken
Implemented a polymorphic `Identifier` model with domain-prefixed enum types for clear identification. Used PostgreSQL 17 optimized indexing strategy with two composite indexes for efficient lookups. Created a focused `IdentifierService` for business logic, emphasizing data import and deduplication workflows.

### Key Files Changed
- `web-app/app/models/identifier.rb` - New polymorphic model with 47 identifier types
- `web-app/db/migrate/20250727171428_create_identifiers.rb` - Migration with optimized indexes
- `web-app/app/lib/identifier_service.rb` - Service object for business logic
- `web-app/test/models/identifier_test.rb` - Comprehensive model tests
- `web-app/test/lib/identifier_service_test.rb` - Service object tests
- `web-app/test/fixtures/identifiers.yml` - Test fixtures
- `web-app/app/models/music/artist.rb` - Added `has_many :identifiers` association
- `web-app/app/models/music/album.rb` - Added `has_many :identifiers` association
- `web-app/app/models/music/song.rb` - Added `has_many :identifiers` association
- `web-app/app/models/music/release.rb` - Added `has_many :identifiers` association
- `web-app/app/models/movies/movie.rb` - Added `has_many :identifiers` association

### Challenges Encountered
- **Enum Value Ordering**: Initial test for `resolve_identifiers` ordering failed because `order(:identifier_type)` sorts by integer values, not alphabetically. Fixed by explicitly defining expected order in tests.
- **Enum Type Conversion**: Initially had redundant `type.to_s` conversion in service, which was unnecessary as Rails handles enum conversion automatically.
- **Index Optimization**: Initially planned 4 separate indexes, but refined to 2 optimized composite indexes based on PostgreSQL 17 best practices and actual query patterns.

### Deviations from Plan
- **Removed External Link IDs**: Initially included Spotify URIs, YouTube IDs, Apple Music IDs, and Last.fm IDs, but removed these as they serve different purposes (external linking vs data import).
- **Simplified Schema**: Removed `metadata` and `source` columns as they weren't needed for the core use case.
- **Streamlined Service**: Removed `IdentifierResolver`, `statistics`, `identifiers_by_type`, and `remove_identifier` methods to keep the service focused on core data import operations.

### Code Examples
```ruby
# Adding an identifier
result = IdentifierService.add_identifier(artist, :music_musicbrainz_artist_id, "5441c29d-3602-4898-b1a1-b77fa23b8e50")

# Finding by specific identifier
artist = IdentifierService.find_by_identifier(:music_musicbrainz_artist_id, "5441c29d-3602-4898-b1a1-b77fa23b8e50")

# Finding by value across types (ISBN use case)
book = IdentifierService.find_by_value_in_domain("Books::Book", "9780140283334")
```

### Testing Approach
- **Model Tests**: Comprehensive validation tests, enum behavior, scopes, and database constraints
- **Service Tests**: All public methods tested with success/failure scenarios, edge cases, and cross-domain isolation
- **Fixtures**: Realistic test data for Music::Artist and Music::Album identifiers
- **Edge Cases**: Whitespace handling, invalid types, duplicate prevention, empty values

### Performance Considerations
- **Optimized Indexes**: Two composite indexes cover all lookup patterns efficiently
- **Polymorphic Associations**: Rails handles type conversion automatically
- **Service Object Pattern**: Business logic isolated for easy testing and maintenance

### Future Improvements
- Add support for Books and Games domains when those models are implemented
- Consider adding movie identifier types when movie import is prioritized
- Potential for bulk identifier operations for large data imports

### Lessons Learned
- PostgreSQL 17 composite indexes are more efficient than multiple single-column indexes
- Rails enum handling is robust and doesn't need manual type conversion
- Polymorphic associations work seamlessly with Rails conventions
- Focused service objects are easier to test and maintain than feature-rich ones

### Related PRs
- Initial implementation completed in single session

### Documentation Updated
- [x] Model documentation created for Identifier
- [x] Service documentation created for IdentifierService
- [x] All affected models updated with identifier associations
- Bulk identifier import/export
- API rate limiting for external lookups