# Music Object Model - Current State

## Overview
The music object model represents the core entities and relationships for The Greatest's music domain. This documentation reflects the current implementation as of August 2025, including changes made since the original design in the [001-music-object-model.md todo](/docs/todos/001-music-object-model.md).

## Core Models

### 1. Music::Artist
**Table**: `music_artists`

Represents both individual people and groups/bands in the music domain.

#### Schema Changes from Original Design
- `died_on` renamed to `year_died` (integer instead of date)
- `formed_on` renamed to `year_formed` (integer instead of date) 
- `disbanded_on` renamed to `year_disbanded` (integer instead of date)
- Added `born_on` (date) for person birth dates

#### Associations
- `has_many :band_memberships` (as the band)
- `has_many :memberships` (as the member/person)
- `has_many :album_artists` - Join table for album associations
- `has_many :albums, through: :album_artists` - Multiple albums association
- `has_many :song_artists` - Join table for song associations
- `has_many :songs, through: :song_artists` - Multiple songs association
- `has_many :credits`
- `has_many :ai_chats, as: :parent`
- `has_many :identifiers, as: :identifiable`
- `has_many :category_items, as: :item`
- `has_many :categories, through: :category_items`

#### Enums
- `kind`: `person` (0), `band` (1)

#### Validations
- Name presence required
- Country must be 2 characters (ISO-3166 alpha-2)
- Date consistency validation (person vs band fields)

#### Key Features
- FriendlyId slugs for URLs
- AI integration for detail population
- Search indexing capability
- Category tagging system

---

### 2. Music::Album
**Table**: `music_albums`

Represents canonical musical works (e.g., "Black Celebration"). Commercial manifestations are handled by releases.

#### Schema Changes from Original Design
- **BREAKING CHANGE**: Removed `primary_artist_id` column (August 2025)
- Now supports multiple artists through join table

#### Associations
- `has_many :album_artists` (ordered by position)
- `has_many :artists, through: :album_artists` - Multiple artists support
- `has_many :releases`
- `has_many :credits, as: :creditable`
- `has_many :ai_chats, as: :parent`
- `has_many :identifiers, as: :identifiable`
- `has_many :category_items, as: :item`
- `has_many :categories, through: :category_items`

#### Key Features
- FriendlyId slugs for URLs
- Search indexing with artist and category data
- Category tagging system

---

### 3. Music::Song
**Table**: `music_songs`

Musical compositions independent of any specific recording.

#### Schema Changes from Original Design
- Added `notes` field for additional song information
- Added `release_year` field directly on songs
- **NEW**: Direct artist associations (August 2025)

#### Associations
- `has_many :song_artists` (ordered by position)
- `has_many :artists, through: :song_artists` - Direct artist associations
- `has_many :tracks`
- `has_many :releases, through: :tracks`
- `has_many :albums, through: :releases`
- `has_many :credits, as: :creditable`
- `has_many :ai_chats, as: :parent`
- `has_many :identifiers, as: :identifiable`
- `has_many :category_items, as: :item`
- `has_many :categories, through: :category_items`

#### Song Relationships
- `has_many :song_relationships` (outbound)
- `has_many :related_songs, through: :song_relationships`
- `has_many :inverse_song_relationships` (inbound)
- `has_many :original_songs, through: :inverse_song_relationships`

#### Helper Methods for Relationships
- `covers`, `remixes`, `samples`, `alternates` (songs this song relates to)
- `covered_by`, `remixed_by`, `sampled_by`, `alternated_by` (songs that relate to this song)

#### Validations
- Title presence required
- Duration must be positive integer (if provided)
- ISRC must be exactly 12 characters (if provided)
- Release year must be reasonable range (1900 to next year)

#### Key Features
- ISRC support for international recording codes
- Comprehensive relationship tracking
- Lyrics storage capability
- Extensive scoping for filtering

---

### 4. Music::Release
**Table**: `music_releases`

Specific commercial releases of albums (different formats, remasters, regional variations).

#### Schema Changes from Original Design
- Added `country` field for regional releases
- Added `labels` array field for multiple record labels
- Added `status` enum for different release types
- Removed unique constraint on `(album_id, release_name, format)` mentioned in original design

#### Associations
- `belongs_to :album`
- `has_many :tracks` (ordered by medium_number, position)
- `has_many :songs, through: :tracks`
- `has_many :credits, as: :creditable`
- `has_many :identifiers, as: :identifiable`
- `has_many :song_relationships` (as source_release)

#### Enums
- `format`: `vinyl` (0), `cd` (1), `digital` (2), `cassette` (3), `other` (4)
- `status`: `official` (0), `promotion` (1), `bootleg` (2), `pseudo_release` (3), `withdrawn` (4), `expunged` (5), `cancelled` (6)

#### Key Features
- JSONB metadata for flexible release information
- Multiple format support
- Release status tracking
- Country/regional tracking
- Multiple record label support

---

### 5. Music::Track
**Table**: `music_tracks`

Join table representing the track listing of a specific release.

#### Schema Changes from Original Design
- `disc_number` renamed to `medium_number` for clarity
- Removed credits association (commented out)

#### Associations
- `belongs_to :release`
- `belongs_to :song`

#### Key Features
- Multi-disc/medium support
- Position tracking within medium
- Release-specific track lengths
- Unique constraint on (release_id, medium_number, position)

---

### 6. Music::Membership
**Table**: `music_memberships`

Records a person's membership in a band, including tenure dates.

#### Associations
- `belongs_to :artist` (the band)
- `belongs_to :member` (the person)

#### Validations
- Artist must be a band
- Member must be a person
- Member cannot be same as artist
- Date consistency (left_on >= joined_on)

#### Key Features
- Temporal membership tracking
- Active/former member scoping
- Unique constraint on (artist_id, member_id, joined_on)

---

### 7. Music::Credit
**Table**: `music_credits`

Polymorphic model for all artistic and technical roles across songs, albums, and releases.

#### Associations
- `belongs_to :artist`
- `belongs_to :creditable, polymorphic: true`

#### Enums
- `role`: `writer` (0), `composer` (1), `lyricist` (2), `arranger` (3), `performer` (4), `vocalist` (5), `guitarist` (6), `bassist` (7), `drummer` (8), `keyboardist` (9), `producer` (10), `engineer` (11), `mixer` (12), `mastering` (13), `featured` (14), `guest` (15), `remixer` (16), `sampler` (17)

#### Key Features
- Works with Songs, Albums, and Releases
- Position ordering within same role
- Comprehensive role coverage

---

### 8. Music::SongRelationship
**Table**: `music_song_relationships`

Self-referential relationships between songs (covers, remixes, samples, alternates).

#### Associations
- `belongs_to :song` (original)
- `belongs_to :related_song` (cover/remix/etc.)
- `belongs_to :source_release, optional: true`

#### Enums
- `relation_type`: `cover` (0), `remix` (1), `sample` (2), `alternate` (3)

#### Key Features
- Tracks where related versions appear
- Prevents self-references
- Unique constraint on (song_id, related_song_id, relation_type)

---

### 9. Music::Category
**Table**: `categories` (STI)

Music-specific categories that inherit from the global Category model.

#### Associations
- `has_many :albums, through: :category_items`
- `has_many :songs, through: :category_items`
- `has_many :artists, through: :category_items`

#### Key Features
- Single Table Inheritance from global Category
- Music-specific scoping methods
- Supports hierarchical categorization

---

### 10. Music::AlbumArtist
**Table**: `music_album_artists`

Join table for many-to-many relationship between albums and artists.

#### Associations
- `belongs_to :album`
- `belongs_to :artist`

#### Key Features
- Position-based ordering for multiple artists
- Unique constraint on (album_id, artist_id)
- Validates artist uniqueness per album
- Supports ordered artist lists (e.g., "Artist A & Artist B")

---

### 11. Music::SongArtist  
**Table**: `music_song_artists`

Join table for many-to-many relationship between songs and artists.

#### Associations
- `belongs_to :song`
- `belongs_to :artist`

#### Key Features
- Position-based ordering for multiple artists
- Unique constraint on (song_id, artist_id) 
- Validates artist uniqueness per song
- Enables songs to have different artists than their albums

---

### 12. Music::Penalty
**Table**: `penalties` (STI)

Music-specific penalties that inherit from the global Penalty model.

#### Key Features
- Single Table Inheritance from global Penalty
- Extensible for music-specific penalty logic

---

## Key Architectural Patterns

### 1. Namespacing
All models are namespaced under `Music::` for clear domain separation.

### 2. STI Integration
Uses Single Table Inheritance for Categories and Penalties to share common functionality while allowing domain-specific extensions.

### 3. Polymorphic Associations
- Credits work across Songs, Albums, and Releases
- AI chats, identifiers, and category items work across all music entities

### 4. Search Integration
All major models include `SearchIndexable` concern and implement `as_indexed_json` for OpenSearch integration.

### 5. AI Integration
All major models support AI chat associations for content enrichment.

### 6. FriendlyId
Artists, Albums, and Songs use FriendlyId for SEO-friendly URLs.

### 7. Category System
All major entities (Artists, Albums, Songs) participate in the category system for flexible tagging and organization.

## Changes from Original Design

1. **Date Fields**: Changed from `date` to `integer` fields for years on Artist model
2. **Field Names**: `disc_number` → `medium_number`, `died_on` → `year_died`, etc.
3. **Additional Fields**: Added `notes`, `release_year`, `country`, `labels`, `status`
4. **Relationships**: Added extensive song relationship tracking
5. **Integration**: Added AI, search, identifier, and category integrations
6. **STI Models**: Added Category and Penalty inheritance
7. **MAJOR CHANGE (August 2025)**: Replaced single artist relationships with multiple artist support
   - Removed `primary_artist_id` from albums
   - Added `music_album_artists` join table
   - Added `music_song_artists` join table  
   - Updated all related systems (search, data importers, admin, tests)

## Database Schema Summary

### Core Tables
- `music_artists` - People and bands
- `music_albums` - Canonical works  
- `music_songs` - Musical compositions
- `music_releases` - Commercial manifestations
- `music_tracks` - Track listings

### Relationship Tables
- `music_album_artists` - Album-artist many-to-many (NEW August 2025)
- `music_song_artists` - Song-artist many-to-many (NEW August 2025)
- `music_memberships` - Band membership
- `music_credits` - All roles (polymorphic)
- `music_song_relationships` - Song connections

### Shared Tables (STI)
- `categories` - Tagging system
- `penalties` - Ranking penalties
- `category_items` - Many-to-many for categories
- `identifiers` - External ID tracking
- `ai_chats` - AI interaction history

## Current Status
✅ **Implemented**: All core models with full associations and validations  
✅ **Tested**: Comprehensive test coverage with fixtures  
✅ **Admin**: Avo resources for content management  
✅ **Search**: OpenSearch integration for all major models  
✅ **AI**: AI task integration for content enrichment  
✅ **Categories**: Flexible tagging system integrated
✅ **Multiple Artists**: Support for multiple artists per album and song (August 2025)

## Known Issues & Future Considerations
- Track credits association is currently commented out
- May need genre lookup tables for more structured categorization
- Consider adding more sophisticated audio metadata support
- Album artwork and media asset management not yet implemented
- Artist validation can be added back if needed (currently disabled for flexibility)

---

*Last Updated: August 2025*  
*Next Review: When implementing reported issues or adding new music features*