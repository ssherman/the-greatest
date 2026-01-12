# Music::Category

## Summary
Music-specific category model for categorizing albums, artists, and songs. Inherits from base Category model with music-specific associations and scopes.

## Associations
- `has_many :albums, through: :category_items, source: :item, source_type: 'Music::Album'` - Albums in this category
- `has_many :songs, through: :category_items, source: :item, source_type: 'Music::Song'` - Songs in this category
- `has_many :artists, through: :category_items, source: :item, source_type: 'Music::Artist'` - Artists in this category

## Public Methods
Inherits all methods from base Category model, including:
- `#soft_delete!` - Soft-delete the category (sets `deleted: true`)

## Validations
Inherits all validations from base Category model.

## Scopes
- `by_album_ids(album_ids)` - Find categories containing specific albums
- `by_song_ids(song_ids)` - Find categories containing specific songs
- `by_artist_ids(artist_ids)` - Find categories containing specific artists

## Constants
Inherits all constants from base Category model.

## Callbacks
Inherits all callbacks from base Category model.

## Dependencies
- Base Category model
- Music::Album, Music::Song, Music::Artist models
- Polymorphic CategoryItem associations

## Admin Interface
Custom admin interface at `/admin/categories` provides:
- Index with search (SQL ILIKE), sorting (name, category_type, item_count), pagination (25/page)
- Show page with albums/artists/songs counts breakdown
- Create/Edit with parent category selection
- Soft delete (sets `deleted: true`)

See: `Admin::Music::CategoriesController` (`app/controllers/admin/music/categories_controller.rb`)

Documentation: `docs/controllers/admin/music/categories_controller.md`

## Usage Examples
```ruby
# Create a music genre category
rock = Music::Category.create!(name: "Rock", category_type: "genre")

# Add albums to the category
rock.albums << dark_side_album
rock.albums << wish_you_were_here_album

# Find all rock albums
rock.albums

# Find categories by album
Music::Category.by_album_ids([album1.id, album2.id])

# Soft delete a category
rock.soft_delete!
```
