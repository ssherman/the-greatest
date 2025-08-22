# 023 - Data Importer Service - Music Songs and Tracks (Phase 2)

## Status
- **Status**: Completed
- **Priority**: High
- **Created**: 2025-08-21
- **Started**: 2025-08-21
- **Completed**: 2025-08-21
- **Developer**: AI Assistant

## Overview
Implement the fourth phase of the flexible data import system for Music::Song and Music::Track imports from MusicBrainz. This builds upon the established architecture from the Music::Artist, Music::Album, and Music::Release importers, extending the domain-agnostic base classes to support song and track imports for existing releases.

## Context
- Why is this needed?
  - Need automated way to populate song and track data for existing releases from external sources
  - Manual song/track entry is time-consuming and error-prone for large discographies
  - Complements release import system to build comprehensive music catalog with complete track listings
  - Enables full music discovery platform with detailed song-level information and cross-references

- What problem does it solve?
  - Reduces manual effort in populating song and track information for releases
  - Ensures consistent, high-quality song data from authoritative sources
  - Enables bulk song/track imports for release catalogs
  - Creates foundation for song-level features like recommendations, playlists, and cross-references
  - Provides structured data for song relationships (covers, remixes, samples, alternates)

- How does it fit into the larger system?
  - Extends existing DataImporters architecture established in previous phases
  - Uses existing MusicBrainz ReleaseSearch API (with `inc=recordings+media` parameter)
  - Integrates with existing IdentifierService for deduplication
  - Follows domain-driven design principles with Music:: namespace
  - Works with existing Music::Song, Music::Track, and Music::Release models
  - Leverages existing RecordingSearch service for additional song metadata

## Requirements
- [ ] Reuse existing Release importer architecture without creating new importers
- [ ] Enhance existing MusicBrainz provider to also create songs and tracks
- [ ] Continue using existing Music::Album as input parameter (no API changes)
- [ ] Use existing type-safe ImportQuery (no changes needed)
- [ ] Integrate MusicBrainz release search with `inc=recordings+media` to get track data
- [ ] Support provider aggregation (multiple providers can populate songs/tracks)
- [ ] Provide enhanced import results showing releases, songs, and tracks created
- [ ] Follow existing service object patterns and core values
- [ ] Create both Music::Song and Music::Track records from MusicBrainz data
- [ ] Handle song deduplication across multiple releases (same recording = same song)
- [ ] Parse track-specific data (position, medium_number, length_secs)
- [ ] Parse song-specific data (title, duration_secs, ISRC, release_year)

## Technical Approach

### Revised Approach: Extend Existing Release Importer
Rather than creating separate Song and Track importers, we'll enhance the existing Release importer to also create songs and tracks during the same operation. This is much more efficient since we're already calling the MusicBrainz release API.

### Enhanced Release Import Architecture (Reusing Existing Classes)
```ruby
DataImporters::Music::Release::
  Importer < ImporterBase        # Existing - no changes needed
  Finder < FinderBase           # Existing - no changes needed  
  ImportQuery < ImportQuery     # Existing - no changes needed
  Providers::
    MusicBrainz < ProviderBase  # ENHANCED - add song/track creation
```

### MusicBrainz Data Strategy
1. **Enhanced Release Search**: Modify existing ReleaseSearch to include `inc=recordings+media` parameter
2. **Single Import Process**: Create releases, songs, and tracks in one coordinated operation
3. **Song Deduplication**: Same MusicBrainz recording ID = same Music::Song across releases
4. **Track Creation**: Create Music::Track for each track on each release, linking to appropriate song
5. **Recording Metadata**: Use MusicBrainz recording data for song attributes
6. **Track Metadata**: Use MusicBrainz track data for track-specific attributes

### Import Flow (Enhanced)
1. **Input**: Album (existing Music::Album) via existing ImportQuery
2. **Get Release Data**: Fetch MusicBrainz releases with recordings and media included
3. **Process Each Release**: 
   - Create/update Music::Release (existing logic)
   - **NEW**: Extract and process song data from recordings
   - **NEW**: Find existing songs by MusicBrainz recording ID
   - **NEW**: Create new songs for recordings not yet imported
   - **NEW**: Create Music::Track records linking release to songs
4. **Validate & Save**: Save releases, songs, and tracks in coordinated transaction
5. **Return Results**: Enhanced ImportResult with releases, songs, and tracks created

### Query Object Pattern (Unchanged)
```ruby
album = Music::Album.find_by(title: "Black Celebration")
result = DataImporters::Music::Release::Importer.call(album: album)
# Now creates releases AND their songs/tracks automatically
```

### API Design (Simplified)
```ruby
# Import releases AND songs/tracks for an album in one operation
result = DataImporters::Music::Release::Importer.call(album: album)

# Result will include:
# - releases_created: number of releases created
# - songs_created: number of songs created  
# - tracks_created: number of tracks created
```

## Dependencies
- Existing DataImporters base classes (ImporterBase, FinderBase, ProviderBase)
- Existing Music::Musicbrainz::Search::ReleaseSearch service (enhanced with recordings+media)
- Existing Music::Musicbrainz::Search::RecordingSearch service (for additional metadata)
- Existing IdentifierService for deduplication
- Existing Music::Song, Music::Track, and Music::Release models
- MusicBrainz recording identifier type (music_musicbrainz_recording_id)
- MusicBrainz track identifier type (music_musicbrainz_track_id) - may need to be added

## Acceptance Criteria
- [ ] User can import releases, songs, and tracks in one operation: `DataImporters::Music::Release::Importer.call(album: album)`
- [ ] No API changes needed - existing release import API automatically creates songs/tracks
- [ ] System finds existing songs using MusicBrainz recording identifiers (deduplication)
- [ ] Same recording creates only one Music::Song, even if on multiple releases
- [ ] New songs are created with MusicBrainz recording data when no match found
- [ ] Tracks are created linking releases to appropriate songs
- [ ] Songs are properly populated with recording metadata (title, duration, ISRC, etc.)
- [ ] Tracks are properly populated with track metadata (position, medium_number, length)
- [ ] Enhanced results show releases, songs, and tracks created in one operation
- [ ] Base classes are reused without modification (only provider enhanced)
- [ ] All code follows naming conventions and service object patterns
- [ ] Multi-item import pattern extended to handle releases + songs + tracks

## Design Decisions
- **Reuse Existing Architecture**: Leverage existing Release importer without creating new importers
- **Album-Centric Import**: Continue using existing album input (no API changes)
- **Enhanced Release Search**: Modify existing ReleaseSearch to include recordings+media
- **Song Deduplication**: Use MusicBrainz recording ID to prevent duplicate songs
- **Single Coordinated Process**: One importer creates releases, songs, and tracks together
- **Provider Enhancement**: Extend existing MusicBrainz provider rather than create new ones
- **Query Object Reuse**: Use existing ImportQuery without changes
- **Enhanced Multi-Item Import**: Extend pattern to handle releases + songs + tracks

## Data Mapping Strategy

### MusicBrainz Release Data Structure
```json
{
  "media": [
    {
      "title": "",
      "format-id": "9712d52a-4509-3d4b-a1a2-67c88c643e31", 
      "id": "9b558bc4-54f4-399d-8aa9-52dee41ef012",
      "tracks": [
        {
          "length": 294333,
          "id": "39284883-cc88-317a-9242-b4b389b47cd4",
          "title": "Black Celebration",
          "number": "1", 
          "position": 1,
          "recording": {
            "first-release-date": "1986-03-17",
            "disambiguation": "",
            "video": false,
            "title": "Black Celebration", 
            "length": 297080,
            "id": "81e5cda0-5ceb-4b40-bce1-e1473b5108a2"
          }
        }
      ]
    }
  ]
}
```

### MusicBrainz Recording → Music::Song
- `recording.title` → `title`
- `recording.length` (ms) → `duration_secs` (convert ms to seconds)
- `recording.id` → MusicBrainz recording identifier
- `recording.first-release-date` → `release_year` (extract year)
- `recording.disambiguation` → `notes` (changed from description during implementation)
- ISRC from recording data → `isrc`
- Album from release → indirect association through tracks

### MusicBrainz Track → Music::Track
- `track.position` → `position`
- Track's media index → `medium_number` (1-based)
- `track.length` (ms) → `length_secs` (convert ms to seconds)
- `track.title` → `notes` (if different from recording title)
- Release from query → `release_id`
- Song found/created from recording → `song_id`

### Identifier Strategy
- **Songs**: Use `music_musicbrainz_recording_id` with recording.id
- **Tracks**: Use `music_musicbrainz_track_id` with track.id (if needed for future features)

### Deduplication Logic
1. **Song Deduplication**: Same `recording.id` across multiple releases = same Music::Song
2. **Track Uniqueness**: Each track on each release gets its own Music::Track record
3. **Existing Song Check**: Query by MusicBrainz recording identifier before creating
4. **Track Association**: Link track to existing or newly created song

## Implementation Strategy

### Phase 1: Enhanced Release Search
1. Modify ReleaseSearch to include `inc=recordings+media` parameter
2. Update search method signatures to support enhanced data
3. Verify enhanced API responses include track and recording data

### Phase 2: Enhanced MusicBrainz Provider
1. Add song creation logic to existing MusicBrainz provider
2. Add track creation logic to existing MusicBrainz provider  
3. Implement song deduplication using recording identifiers
4. Handle multi-media releases (multiple discs/sides)

### Phase 3: Integration and Testing
1. Update provider result reporting to include songs/tracks created
2. Add comprehensive test coverage for enhanced functionality
3. Update admin interfaces to show imported songs/tracks
4. Document enhanced import workflows

---

## Implementation Notes

### Approach Taken
Successfully implemented song and track import by enhancing the existing Release importer architecture rather than creating separate importers. This approach proved to be much more efficient and maintainable.

### Key Files Created/Modified

#### Database Changes
- `db/migrate/20250822032825_add_notes_to_music_songs.rb` - Added notes field for MusicBrainz disambiguation data

#### Enhanced MusicBrainz Search
- `app/lib/music/musicbrainz/search/base_search.rb` - Added browse API support with `browse_by_params()` method
- `app/lib/music/musicbrainz/search/release_search.rb` - Added `search_by_release_group_mbid_with_recordings()` using browse API

#### Enhanced Release Provider
- `app/lib/data_importers/music/release/providers/music_brainz.rb` - Enhanced to create songs and tracks alongside releases

#### Model Updates
- `app/models/music/song.rb` - Added `with_notes` scope for new notes field

#### Admin Interface
- `app/avo/resources/music_song.rb` - Added notes field to admin interface

### Challenges Encountered

1. **MusicBrainz API Limitation**: Initially used search API (`query=rgid:...`) which doesn't return detailed media/recording data with `inc` parameter. **Solution**: Implemented browse API support (`release-group=mbid&inc=recordings+media`) in BaseSearch.

2. **Data Field Mapping**: Originally planned to use `description` field for MusicBrainz disambiguation data, but realized this was more like "notes". **Solution**: Added dedicated `notes` field to music_songs table.

3. **Architecture Decision**: Initially planned separate Song/Track importers. **Solution**: Enhanced existing Release importer to handle all three entity types in one coordinated operation.

### Deviations from Plan

1. **Browse API Implementation**: Added comprehensive browse API support to BaseSearch class, which wasn't in original plan but provides better architecture for future non-search operations.

2. **Notes Field Addition**: Added `notes` field to Music::Song model for MusicBrainz disambiguation data instead of using existing `description` field.

3. **Single Coordinated Import**: Implemented as enhancement to Release importer rather than separate importers, providing better data consistency and performance.

### Code Examples

#### Enhanced Release Import Usage
```ruby
# Import releases, songs, and tracks for an album in one operation
album = Music::Album.find_by(title: "Black Celebration")
result = DataImporters::Music::Release::Importer.call(album: album)

if result.success?
  metadata = result.provider_results.first.metadata
  puts "Created #{metadata[:releases_created]} releases"
  puts "Created #{metadata[:songs_created]} songs"  
  puts "Created #{metadata[:tracks_created]} tracks"
end
```

#### Browse API Usage
```ruby
# Use browse API for detailed MusicBrainz data
release_search = Music::Musicbrainz::Search::ReleaseSearch.new
result = release_search.search_by_release_group_mbid_with_recordings(release_group_mbid)
```

### Testing Approach
- Enhanced existing Release importer tests to verify song and track creation
- Verified browse API functionality returns detailed media and recording data
- Confirmed song deduplication works across multiple releases

### Performance Considerations
- **Single API Call**: One MusicBrainz browse API call gets all data (releases + songs + tracks)
- **Coordinated Transaction**: All related records created in single database transaction
- **Song Deduplication**: Efficient lookup using MusicBrainz recording identifiers

### Future Improvements
- **Song Relationships**: Detect and create covers, remixes, samples, alternates
- **Additional Providers**: Discogs, AllMusic for song/track data
- **Enhanced Metadata**: Lyrics, song credits, detailed timing information
- **Batch Import**: Import entire catalog song/track data efficiently
- **Cross-Release Analysis**: Identify same songs across different releases
- **AI-Enhanced Matching**: Better song matching and metadata enrichment

### Lessons Learned

1. **Browse vs Search APIs**: MusicBrainz has different APIs for different use cases. Search API is for finding entities, Browse API is for getting detailed related data. Understanding this distinction is crucial for getting the right data.

2. **Architecture Simplicity**: Enhancing existing importers is often better than creating new ones when the data is naturally related (releases + songs + tracks).

3. **Field Naming Matters**: Taking time to think about proper field names (`notes` vs `description`) leads to clearer data models and better user understanding.

4. **Coordinated Imports**: Creating related entities together ensures data consistency and better performance than separate import operations.

### Related PRs
- Enhanced MusicBrainz search architecture with browse API support
- Added notes field to Music::Song model
- Enhanced Release importer to create songs and tracks
- Updated Avo admin interface for new notes field

### Documentation Updated
- [x] Todo documentation completed with implementation details
- [x] API usage examples provided for enhanced Release importer
- [x] Database schema changes documented
