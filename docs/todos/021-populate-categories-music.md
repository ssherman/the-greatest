# 021 - Populate Categories from MusicBrainz Tags

## Status
- **Status**: Completed
- **Priority**: High
- **Created**: 2025-08-11
- **Started**: 2025-08-11
- **Completed**: 2025-08-12
- **Developer**: AI Assistant

## Overview
Implement automatic category creation and association when importing music artists and albums from MusicBrainz. Extract genre tags and location data from MusicBrainz API responses and create Music::Category records with proper case formatting and count-based prioritization.

## Context
- MusicBrainz provides rich tagging data for artists and albums that can be used for automatic categorization
- MusicBrainz also provides location data (area, begin-area) that can be used for geographic categorization
- Categories are essential for content discovery and filtering across the platform
- Manual category creation is time-consuming and error-prone
- MusicBrainz tags provide a reliable source of genre information with community validation
- Location data provides geographic context for artists and their music
- This will populate the categories system we just implemented with real data

## Requirements
- [x] Extract tags from MusicBrainz API responses for both artists and albums
- [x] Filter tags by count (exclude tags with count = 0)
- [x] Sort tags by count in descending order
- [x] Take top 5 tags for category creation
- [x] Normalize tag names (proper case formatting - each word capitalized; preserve hyphens)
- [x] Extract location data from MusicBrainz API responses (area, begin-area) for artists only
- [x] Create Music::Category records for genres with:
  - `name`: Normalized tag name
  - `category_type`: "genre"
  - `import_source`: "musicbrainz"
- [x] Create Music::Category records for locations with:
  - `name`: Location name (e.g., "United Kingdom", "Basildon")
  - `category_type`: "location"
  - `import_source`: "musicbrainz"
- [x] Associate created categories with the imported artist/album
- [x] Handle duplicate category names gracefully (find existing or create new)
- [x] Implement in both artist and album MusicBrainz providers (locations only for artist provider)
- [x] Add proper error handling for category creation failures (log and re-raise)

## Technical Approach

### Data Flow
1. **MusicBrainz API Response** → Extract `tags` array for artists and albums; extract location data (`area`, `begin-area`) for artists only
2. **Tag Processing** → Filter, sort, normalize genre tags
3. **Location Processing** → Extract and normalize location names (artists only)
4. **Category Creation** → Find or create Music::Category records for both genres and locations
5. **Association** → Link categories to imported item

### Tag Processing Logic
```ruby
# Example processing flow
tags = [
  {"count" => 25, "name" => "electronic"},
  {"count" => 0, "name" => "downtempo"},      # Excluded (count = 0)
  {"count" => 19, "name" => "synth-pop"},
  {"count" => 9, "name" => "alternative rock"},
  {"count" => 8, "name" => "british"},
  {"count" => 6, "name" => "dark wave"}
]

# After processing:
# 1. Electronic (25)
# 2. Synth-Pop (19)
# 3. Alternative Rock (9)
# 4. British (8)
# 5. Dark Wave (6)
```

### Location Processing Logic
```ruby
artist_data = {
  "area" => {"name" => "United Kingdom", "type" => "Country"},
  "begin-area" => {"name" => "Basildon", "type" => "City"}
}

# Location categories to create:
# 1. "United Kingdom"
# 2. "Basildon"
```

### Case Normalization
- Input: "alternative rock" → "Alternative Rock"
- Input: "synth-pop" → "Synth-Pop"
- Input: "electronic" → "Electronic"

### Category Creation Strategy
1. **Find Existing**: Search for category with exact normalized name and category_type
2. **Create New**: If not found, create new Music::Category with appropriate type inferred by STI
3. **Associate**: Link category to imported item via `CategoryItem`

### Category Types
- **Genre Categories**: Created from MusicBrainz tags with `category_type: "genre"`
- **Location Categories**: Created from area/begin-area data with `category_type: "location"` (artists only)

## Dependencies
- Categories system implementation (completed)
- MusicBrainz API wrapper (completed)
- Music::Album and Music::Artist models with category associations
- MusicBrainz provider classes for artists and albums

## Acceptance Criteria
- [x] When importing an artist from MusicBrainz, top 5 non-zero tags become genre categories
- [x] When importing an artist from MusicBrainz, location data (area, begin-area) becomes location categories
- [x] When importing an album from MusicBrainz, top 5 non-zero tags become genre categories
- [x] Category names are properly capitalized (e.g., "Alternative Rock")
- [x] Genre categories are created with correct metadata (genre type, musicbrainz source)
- [x] Location categories are created with correct metadata (location type, musicbrainz source)
- [x] Duplicate category names are handled gracefully (reuse existing categories within same type)
- [x] Import process raises on category creation failures (logged and re-raised)
- [x] Categories are properly associated with imported items
- [x] No categories are created for tags with count = 0
- [x] Location categories include both country and city information when available

## Design Decisions

### Tag Count Threshold
- **Decision**: Exclude tags with count = 0
- **Rationale**: Zero count indicates no community validation

### Top 5 Limit
- **Decision**: Limit to top 5 tags by count
- **Rationale**: Prevents noise and category spam

### Case Normalization
- **Decision**: Capitalize each word; preserve hyphens
- **Rationale**: Readability; keeps compound-words intact

### Category Types
- **Decision**: MusicBrainz tags → "genre"; area/begin-area → "location"
- **Rationale**: Straightforward mapping; extensible later

### Error Handling
- **Decision**: Log and re-raise exceptions in provider category creation methods
- **Rationale**: Avoids silent failures; surfaces issues in tests and runtime

---

## Implementation Notes

### Approach Taken
- Implemented inline in providers. Genres for artists and albums; locations for artists only.
- Used `::Music::Category.find_or_create_by!` with `category_type` and `import_source`.
- Associated via `::CategoryItem.find_or_create_by!` to avoid through-write quirks.
- Normalized names preserving hyphens.
- Logged and re-raised errors in category creation.

### Key Files Changed
- `app/lib/data_importers/music/artist/providers/music_brainz.rb`
- `app/lib/data_importers/music/album/providers/music_brainz.rb`
- `test/lib/data_importers/music/artist/providers/music_brainz_test.rb`
- `test/lib/data_importers/music/album/providers/music_brainz_test.rb`

### Challenges Encountered
- Constant resolution inside `DataImporters` namespace; fixed with `::Music::Category`.
- Initially silent rescues hid failures; switched to re-raise.

### Deviations from Plan
- Removed explicit STI `type` assignment; Rails sets `type` automatically.

### Code Examples
```ruby
# Artist genre + location
::CategoryItem.find_or_create_by!(category: genre_category, item: artist)
::CategoryItem.find_or_create_by!(category: location_category, item: artist)

# Album genre only
::CategoryItem.find_or_create_by!(category: genre_category, item: album)
```

### Testing Approach
- Stubbed MusicBrainz responses with tags and location data
- Verified top 5 tag selection, normalization, and associations
- Confirmed no location categories for albums

### Future Improvements
- Tag whitelist/blacklist
- Location hierarchy (city → country) relationships