# Category

## Summary
Base model for categorizing content across all media types using Single Table Inheritance (STI). Supports genres, locations, and subjects with hierarchical relationships and soft deletion.

## Associations
- `belongs_to :parent, class_name: "Category", optional: true` - Parent category for hierarchical relationships
- `has_many :child_categories, class_name: "Category", foreign_key: :parent_id, dependent: :nullify` - Child categories in hierarchy
- `has_many :category_items, dependent: :destroy` - Polymorphic join table for item associations
- `has_many :ai_chats, as: :parent, dependent: :destroy` - AI chat sessions related to this category

## Public Methods

### `#soft_delete!`
Soft-deletes the category by setting `deleted: true`.
- Returns: Boolean (success of update)
- Side effects: Updates `deleted` column, does not destroy record

### `#to_param`
Returns the slug for URL generation
- Returns: String (slug)

### `#should_generate_new_friendly_id?`
Determines if FriendlyId should regenerate the slug
- Returns: Boolean (true if slug blank or name changed)

## Validations
- `name` - presence required
- `type` - presence required (STI discriminator)

## Scopes
- `active` - Categories that are not soft deleted (`deleted: false`)
- `soft_deleted` - Categories that are soft deleted (`deleted: true`)
- `sorted_by_name` - Alphabetical order by name
- `sorted_by_item_count` - Order by item count descending
- `search(query)` - Partial name match (case insensitive)
- `search_by_name(name)` - Full name search with LIKE
- `by_name(name)` - Exact name match (case insensitive)
- `by_alternative_name(name)` - Search by alternative names array

## Constants
- `category_type` enum: `{ genre: 0, location: 1, subject: 2 }`
- `import_source` enum: `{ amazon: 0, open_library: 1, openai: 2, goodreads: 3, musicbrainz: 4 }`

## Callbacks
- `before_validation` - FriendlyId slug generation when name changes

## Dependencies
- FriendlyId gem for slug generation with scoped slugs and finders (`[:slugged, :scoped, :finders]`)
- PostgreSQL array support for alternative_names
- STI for media-specific category types

## STI Subclasses
- `Music::Category` - Categories for music content (albums, artists, songs)
- `Movies::Category` - Categories for movie content
- `Books::Category` - Categories for book content (future)
- `Games::Category` - Categories for game content (future)
