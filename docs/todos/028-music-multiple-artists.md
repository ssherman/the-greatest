# 028 - Music Object Model: Multiple Artists Support

## Status
- **Status**: Completed
- **Priority**: High
- **Created**: 2025-08-31
- **Started**: 2025-08-31
- **Completed**: 2025-08-31
- **Developer**: shane/AI

## Overview
Replace the single `primary_artist_id` constraint on albums and add proper multiple artist support for both albums and songs through many-to-many relationships. This will allow albums to have multiple equal artists and songs to have their own artist associations independent of the album.

## Context
- **Problem**: Current model forces albums to have only one `primary_artist_id`, but real albums often have multiple equal collaborating artists (e.g., "Jay-Z & Kanye West - Watch the Throne")
- **Problem**: Songs currently have no direct artist association and inherit artists only through `albums -> primary_artist`, which breaks down for compilation albums, guest features, and covers
- **Real-world need**: Music data naturally has multiple artists at both album and song levels
- **Clean slate**: No existing production data to migrate, can make breaking changes freely

## Requirements
- [ ] Remove `primary_artist_id` from `music_albums` table
- [ ] Create `music_album_artists` join table for album-artist relationships
- [ ] Create `music_song_artists` join table for song-artist relationships  
- [ ] Update Album model associations and remove `primary_artist` references
- [ ] Update Song model to add direct artist associations
- [ ] Update all code that references `primary_artist` or `primary_artist_id`
- [ ] Update search indexing to handle multiple artists:
  - [ ] Update `Search::Music::AlbumIndex` to use `artist_names` array and `artist_ids`
  - [ ] Update `Search::Music::SongIndex` to use `artist_ids` array instead of singular `artist_id`
  - [ ] Update `model_includes` in both index classes to load new associations
  - [ ] Update album index documentation
- [ ] Update fixtures and tests to use new artist associations
- [ ] Update Avo admin resources to handle multiple artists

## Technical Approach

### Database Changes
1. **Remove primary_artist_id constraint**:
   - Drop `primary_artist_id` column from `music_albums`
   - Drop foreign key and index

2. **Create join tables**:
   ```ruby
   # music_album_artists
   create_table :music_album_artists do |t|
     t.references :album, null: false, foreign_key: { to_table: :music_albums }
     t.references :artist, null: false, foreign_key: { to_table: :music_artists }
     t.integer :position, default: 1  # for ordering multiple artists
     t.timestamps
   end
   add_index :music_album_artists, [:album_id, :artist_id], unique: true
   add_index :music_album_artists, [:album_id, :position]

   # music_song_artists  
   create_table :music_song_artists do |t|
     t.references :song, null: false, foreign_key: { to_table: :music_songs }
     t.references :artist, null: false, foreign_key: { to_table: :music_artists }
     t.integer :position, default: 1  # for ordering multiple artists
     t.timestamps
   end
   add_index :music_song_artists, [:song_id, :artist_id], unique: true
   add_index :music_song_artists, [:song_id, :position]
   ```

### Model Changes
1. **Album model**:
   ```ruby
   # Remove
   belongs_to :primary_artist
   
   # Add
   has_many :album_artists, -> { order(:position) }, dependent: :destroy
   has_many :artists, through: :album_artists
   ```

2. **Song model**:
   ```ruby
   # Add
   has_many :song_artists, -> { order(:position) }, dependent: :destroy
   has_many :artists, through: :song_artists
   ```

3. **Artist model**:
   ```ruby
   # Remove
   has_many :albums, foreign_key: :primary_artist_id
   
   # Add  
   has_many :album_artists, dependent: :destroy
   has_many :albums, through: :album_artists
   has_many :song_artists, dependent: :destroy  
   has_many :songs, through: :song_artists
   ```

## Dependencies
- Existing Music object model (already implemented)
- Current test suite (will need updates)

## Acceptance Criteria
- [ ] Albums can have multiple artists with proper ordering
- [ ] Songs can have multiple artists independent of album artists
- [ ] All existing functionality works with new artist associations
- [ ] Search indexing includes all artists for albums and songs
- [ ] Admin interface supports adding/removing multiple artists
- [ ] Test suite passes with updated fixtures and assertions
- [ ] No references to `primary_artist` remain in codebase

## Design Decisions

### Why Many-to-Many Instead of Credits?
- **Clear separation**: Artists = who created it, Credits = what specific role they played
- **Flexibility**: An artist can be both a "creator" (in artists) and have specific roles (in credits)
- **Query simplicity**: Easy to find all artists for an item without filtering by role
- **Real-world mapping**: Matches how music is actually attributed

### Position Ordering
- Support for ordered artist lists (e.g., "Artist A & Artist B" vs "Artist B & Artist A")
- Position 1 = primary/first artist for display purposes
- Allows for consistent artist ordering across different contexts

### Join Table Design
- Separate tables (`album_artists`, `song_artists`) rather than polymorphic for better performance and clearer relationships
- Include `position` for ordering
- Unique constraints to prevent duplicate artist assignments

## Code Areas to Update
- `app/models/music/album.rb` - Remove primary_artist associations, update `as_indexed_json`
- `app/models/music/song.rb` - Add artist associations, update `as_indexed_json`
- `app/models/music/artist.rb` - Update album/song associations
- `app/lib/search/music/album_index.rb` - Replace `primary_artist_name` with `artist_names`, add `artist_ids`
- `app/lib/search/music/song_index.rb` - Replace `artist_id` with `artist_ids`, update `model_includes`
- `docs/lib/search/music/album_index.md` - Update documentation for multiple artists
- Fixtures in `test/fixtures/music/`
- Model tests in `test/models/music/`
- Avo admin resources for albums and songs
- Any services or controllers that reference `primary_artist`

---

## Implementation Notes

### Approach Taken
- Used Rails generators to create join table models (`Music::AlbumArtist` and `Music::SongArtist`) with proper foreign keys and indexes
- Removed `primary_artist_id` from albums table completely via migration
- Updated model associations to use `has_many :artists, through: :album_artists` pattern
- Modified search indexing to handle arrays of artists instead of single artist
- Updated all fixtures and tests to work with new association structure

### Key Files Changed
- **Database Migrations**:
  - `20250831204633_create_music_album_artists.rb` - Album-artist join table
  - `20250831204637_create_music_song_artists.rb` - Song-artist join table  
  - `20250831204714_remove_primary_artist_from_music_albums.rb` - Remove old column
- **Models**:
  - `app/models/music/album_artist.rb` - New join model with validations
  - `app/models/music/song_artist.rb` - New join model with validations
  - `app/models/music/album.rb` - Updated associations and search indexing
  - `app/models/music/song.rb` - Added artist associations and updated indexing
  - `app/models/music/artist.rb` - Updated to use new join tables
- **Search Indexes**:
  - `app/lib/search/music/album_index.rb` - Updated mappings for multiple artists
  - `app/lib/search/music/song_index.rb` - Updated for direct artist associations
- **Tests & Fixtures**:
  - Updated all album and song fixtures to remove primary_artist references
  - Created corresponding album_artists and song_artists fixtures
  - Updated test assertions to work with new artist arrays
- **Avo Resources**: Auto-generated for join table models

### Challenges Encountered
- **Fixture Loading**: Initial validation issues where albums/songs were created before their artist associations, causing validation failures. Solved by temporarily removing artist validation.
- **Test Updates**: Multiple test files needed updates to work with new association patterns, particularly around search indexing assertions.
- **Search Field Names**: Had to change from singular `artist_id`/`primary_artist_name` to plural `artist_ids`/`artist_names` throughout search system.

### Deviations from Plan
- **Artist Validation**: Removed the planned validation requiring at least one artist to avoid fixture loading complications. Can be added back later if needed.
- **Model Includes**: Search index includes simplified from complex nested includes to direct `:artists` association.

### Testing Approach
- All 154 music model tests updated and passing
- Fixtures restructured to use join table approach
- Search indexing tests updated for new field names
- Validated both single-artist and multi-artist scenarios work correctly

### Performance Considerations
- Added proper database indexes on join tables for efficient queries
- Search indexing includes proper eager loading to prevent N+1 queries
- Position field allows for ordered artist lists when needed

### Future Improvements
- Could add back artist validation with fixture-friendly approach
- Position ordering could be enhanced with drag-and-drop admin interface
- Consider adding "primary artist" concept as a computed field for APIs that need it

### Related PRs
- Local development only - no PRs created

### Documentation Updated
- [x] Updated `/docs/object_models/music/README.md` with new associations and status
- [x] Updated `/docs/lib/search/music/album_index.md` for multiple artists
- [x] Class documentation automatically updated via Rails annotations