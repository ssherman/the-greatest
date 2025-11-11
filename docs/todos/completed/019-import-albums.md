# 019 - Data Importer Service - Music Albums (Phase 1)

## Status
- **Status**: In Progress
- **Priority**: High
- **Created**: 2025-08-05
- **Started**: 2025-08-05
- **Completed**: 
- **Developer**: AI Assistant

## Overview
Implement the second phase of the flexible data import system for Music::Album imports from MusicBrainz. This builds upon the established architecture from the Music::Artist importer, extending the domain-agnostic base classes to support album imports for existing artists.

## Context
- Why is this needed?
  - Need automated way to populate album data for existing artists from external sources
  - Manual album entry is time-consuming and error-prone for large discographies
  - Complements artist import system to build comprehensive music catalog
  - Supports the goal of comprehensive music discovery platform

- What problem does it solve?
  - Reduces manual effort in populating album information for artists
  - Ensures consistent, high-quality album data from authoritative sources
  - Enables bulk album imports for artist discographies
  - Provides foundation for complete music catalog automation

- How does it fit into the larger system?
  - Extends existing DataImporters architecture established in artist import
  - Uses existing MusicBrainz ReleaseGroupSearch API wrapper
  - Integrates with existing IdentifierService for deduplication
  - Follows domain-driven design principles with Music:: namespace
  - Works with existing Music::Album model and associations

## Requirements
- [x] Reuse domain-agnostic base classes from artist importer
- [x] Implement Music::Album specific importer with MusicBrainz provider
- [x] Require existing Music::Artist as input parameter
- [x] Use type-safe query objects for input validation (artist + album title)
- [x] Integrate MusicBrainz release group search with intelligent fallback strategy
- [ ] Support provider aggregation (multiple providers populate same album)
- [x] Provide detailed import results with per-provider feedback
- [x] Follow existing service object patterns and core values

## Technical Approach

### Album Import Architecture (Reusing Base Classes)
```ruby
DataImporters::Music::Album::
  Importer < ImporterBase        # Reuse existing base
  Finder < FinderBase           # Reuse existing base  
  ImportQuery < ImportQuery     # New album-specific query
  Providers::
    MusicBrainz < ProviderBase  # New album provider
```

### MusicBrainz Search Strategy
1. **Primary Albums First**: Use `search_primary_albums_only(artist_mbid)` to find official studio albums
2. **Fallback to General**: If no primary albums found, use `search_by_artist_mbid_and_title(artist_mbid, title)` for broader search
3. **Title Matching**: When album title provided, use MusicBrainz's built-in relevance scoring
4. **Best Match Selection**: Take first result (highest MusicBrainz score)

### Import Flow
1. **Input**: Artist (existing Music::Artist) + optional album title via ImportQuery
2. **Find Existing**: Use AI-assisted Finder to check for existing albums by MusicBrainz release group ID
3. **Initialize**: Create new Music::Album if none found, associated with provided artist
4. **Populate**: MusicBrainz provider contributes album data
5. **Validate & Save**: Save if valid and provider succeeded
6. **Return Results**: Detailed ImportResult with provider feedback

### Query Object Pattern
```ruby
artist = Music::Artist.find_by(name: "Pink Floyd")
query = DataImporters::Music::Album::ImportQuery.new(artist: artist, title: "The Dark Side of the Moon")
result = DataImporters::Music::Album::Importer.call(query)
```

### API Design
```ruby
# Import all albums for an artist
result = DataImporters::Music::Album::Importer.call(artist: artist)

# Import specific album by title
result = DataImporters::Music::Album::Importer.call(artist: artist, title: "Abbey Road")

# With additional options
result = DataImporters::Music::Album::Importer.call(
  artist: artist, 
  title: "Abbey Road",
  primary_albums_only: true
)
```

## Dependencies
- Existing DataImporters base classes (ImporterBase, FinderBase, ProviderBase)
- Existing Music::Musicbrainz::Search::ReleaseGroupSearch service
- Existing IdentifierService for deduplication
- Existing Music::Album and Music::Artist models
- MusicBrainz release group identifier type (music_musicbrainz_release_group_id)

## Acceptance Criteria
- [ ] User can import all albums for artist: `DataImporters::Music::Album::Importer.call(artist: artist)`
- [x] User can import specific album: `DataImporters::Music::Album::Importer.call(artist: artist, title: "Abbey Road")`
- [x] System finds existing albums using MusicBrainz release group identifiers
- [x] Primary albums search used first, with fallback to general search
- [x] Multiple MusicBrainz results are intelligently evaluated and filtered
- [x] New albums are created with MusicBrainz data when no match found
- [x] Albums are properly associated with provided artist
- [x] Detailed results show what the provider accomplished
- [x] Base classes are reused without modification
- [x] All code follows naming conventions and service object patterns

## Design Decisions
- **Reuse Base Architecture**: Leverage existing ImporterBase, FinderBase, ProviderBase
- **Artist-Centric Import**: Require existing artist, don't create new artists
- **Intelligent Search Strategy**: Primary albums first, fallback to general search
- **Title Filtering**: When title provided, filter MusicBrainz results intelligently
- **Provider Aggregation**: Multiple providers can enrich same album (future extensibility)
- **Query Object Validation**: Type-safe input with artist and optional title

## Data Mapping Strategy

### MusicBrainz Release Group → Music::Album
- `title` → `title`
- `first-release-date` → `release_year` (extract year)
- `id` → MusicBrainz release group identifier
- `primary-type` / `secondary-type` → Used for filtering, not stored
- Artist from query → `primary_artist_id`

### Search Strategy Details
1. **Get Artist MBID**: Extract MusicBrainz ID from existing artist's identifiers
2. **Primary Search**: `search_primary_albums_only(artist_mbid)` for official studio albums
3. **Fallback Search**: `search_by_artist_mbid_and_title(artist_mbid, title)` if primary search yields no results
4. **Title Filtering**: If title provided, MusicBrainz returns results sorted by relevance
5. **Best Match Selection**: Take first result (highest MusicBrainz relevance score)

---

## Implementation Notes
*[This section will be filled out during/after implementation]*

### Approach Taken
Implemented album import following the established artist importer pattern:
- Finder replicates MusicBrainz search logic to resolve the release group MBID, then finds existing albums by MBID + artist
- Provider focuses solely on populating `Music::Album` from the chosen release group (title, release_year, identifiers), no duplicate detection
- Importer reuses base orchestration and exposes a clean API: `.call(artist:, title:, primary_albums_only:)`
- Query objects refactored across domains to a consistent validation pattern (`valid?` returns boolean; `validate!` raises)

### Key Files Created
- `app/lib/data_importers/music/album/import_query.rb`
- `app/lib/data_importers/music/album/finder.rb`
- `app/lib/data_importers/music/album/providers/music_brainz.rb`
- `app/lib/data_importers/music/album/importer.rb`

### Challenges Encountered
- Avoiding duplication between finder/provider; moved search to finder, population to provider
- Ensuring namespace correctness for `::Music::Artist` during validation
- Aligning ImportQuery validation pattern and updating existing tests accordingly

### Deviations from Plan
- Refactored ImportQuery validation pattern project-wide for consistency (album + artist)
- Simplified provider (no duplicate check; handled in finder)

### Code Examples
*To be documented during implementation*

### Testing Approach
- Album ImportQuery tests updated to the new validation pattern
- Finder/Provider/Importer tests deferred until code review approval

### Performance Considerations
*To be documented during implementation*

### Future Improvements
- **AI-Assisted Matching**: For ambiguous album titles and better duplicate detection
- **Additional Providers**: Discogs, AllMusic, Wikipedia for album data
- **Enhanced Metadata**: Genre, track listing, album art URLs
- **Batch Import**: Import entire discographies efficiently
- **Release vs Release Group**: Handle multiple releases of same album
- **Collaborative Albums**: Handle albums with multiple primary artists
 - **OpenSearch-backed Finder**: Switch to internal OpenSearch for faster lookups

### Lessons Learned
*To be documented during implementation*

### Related PRs
*To be documented during implementation*

### Documentation Updated
- [ ] Class documentation files created for new album import classes
- [ ] API documentation updated if needed
- [ ] README updated if needed 